/*
** Lus WebAssembly wrapper
** Provides APIs for executing Lus code and running the LSP in a Web Worker
*/

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauthpath.h"
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
#include "lus_wasm.h"

#define EXEC_OUTPUT_BYTES (256u * 1024u)
#define LSP_FRAME_BYTES (16u * 1024u * 1024u)
#define LSP_HEADER_BYTES (8u * 1024u)
#define LSP_OUTPUT_BYTES (LSP_FRAME_BYTES + LSP_HEADER_BYTES)

#define EXEC_TRUNCATION_MESSAGE "\n[Output truncated at 256 KiB.]\n"

struct LusState {
  lua_State *L;
  char *output;
  size_t output_len;
  size_t output_capacity;
  size_t output_limit;
  int output_overflow;
  int output_oom;
  int lsp_loaded;
  int suppress_diagnostics;
  int warnings_enabled;
  int warning_continues;
};

static int output_reserve(LusState *state, size_t needed) {
  size_t capacity;
  char *next;

  if (needed <= state->output_capacity)
    return 1;
  capacity = state->output_capacity ? state->output_capacity : 256;
  while (capacity < needed) {
    if (capacity > ((size_t)-1) / 2) {
      capacity = needed;
      break;
    }
    capacity *= 2;
  }
  next = (char *)realloc(state->output, capacity);
  if (!next) {
    state->output_oom = 1;
    return 0;
  }
  state->output = next;
  state->output_capacity = capacity;
  return 1;
}

static void output_reset(LusState *state, size_t limit) {
  state->output_len = 0;
  state->output_limit = limit;
  state->output_overflow = 0;
  state->output_oom = 0;
  state->warning_continues = 0;
  if (state->output)
    state->output[0] = '\0';
}

static int output_append(LusState *state, const char *data, size_t len) {
  size_t needed;

  if (state->output_overflow || state->output_oom)
    return 0;
  if (len > state->output_limit - state->output_len) {
    size_t prefix_len = state->output_limit - state->output_len;

    while (prefix_len > 0 && prefix_len < len &&
           ((unsigned char)data[prefix_len] & 0xc0) == 0x80)
      prefix_len--;
    if (prefix_len > 0 &&
        output_reserve(state, state->output_len + prefix_len + 1)) {
      memcpy(state->output + state->output_len, data, prefix_len);
      state->output_len += prefix_len;
      state->output[state->output_len] = '\0';
    }
    state->output_overflow = 1;
    return 0;
  }
  if (len > (size_t)-1 - state->output_len - 1) {
    state->output_oom = 1;
    return 0;
  }
  needed = state->output_len + len + 1;
  if (!output_reserve(state, needed))
    return 0;
  memcpy(state->output + state->output_len, data, len);
  state->output_len += len;
  state->output[state->output_len] = '\0';
  return 1;
}

static const char *output_force(LusState *state, const char *data, size_t len) {
  output_reset(state, (size_t)-1);
  if (!output_append(state, data, len)) {
    if (state->output)
      state->output[0] = '\0';
    return "";
  }
  return state->output;
}

static const char *finish_execution_output(LusState *state) {
  static const char marker[] = EXEC_TRUNCATION_MESSAGE;

  if (state->output_oom)
    return output_force(state, "Error: output allocation failed",
                        sizeof("Error: output allocation failed") - 1);
  if (state->output_overflow) {
    state->output_overflow = 0;
    state->output_limit = EXEC_OUTPUT_BYTES;
    output_append(state, marker, sizeof(marker) - 1);
  }
  return state->output;
}

static const char *set_lsp_error(LusState *state, int code,
                                 const char *message) {
  char body[256];
  char frame[384];
  int body_len;
  int frame_len;

  body_len = snprintf(body, sizeof(body),
                      "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{"
                      "\"code\":%d,\"message\":\"%s\"}}",
                      code, message);
  if (body_len < 0 || (size_t)body_len >= sizeof(body))
    return output_force(state, "", 0);
  frame_len = snprintf(frame, sizeof(frame), "Content-Length: %d\r\n\r\n%.*s",
                       body_len, body_len, body);
  if (frame_len < 0 || (size_t)frame_len >= sizeof(frame))
    return output_force(state, "", 0);
  return output_force(state, frame, (size_t)frame_len);
}

static int header_name_is(const char *name, size_t len, const char *expected) {
  size_t i;

  if (strlen(expected) != len)
    return 0;
  for (i = 0; i < len; i++) {
    if (tolower((unsigned char)name[i]) != tolower((unsigned char)expected[i]))
      return 0;
  }
  return 1;
}

/* Validate every complete frame captured from the shared LSP transport. */
static int validate_lsp_output(const char *output, size_t len) {
  size_t frame_start = 0;

  while (frame_start < len) {
    size_t header_end = frame_start;
    size_t line_start;
    size_t content_length = 0;
    int have_content_length = 0;

    while (header_end + 3 < len &&
           memcmp(output + header_end, "\r\n\r\n", 4) != 0) {
      header_end++;
      if (header_end - frame_start > LSP_HEADER_BYTES)
        return 0;
    }
    if (header_end + 3 >= len || header_end == frame_start)
      return 0;

    line_start = frame_start;
    while (line_start < header_end) {
      size_t line_end = line_start;
      size_t colon;
      size_t i;

      while (line_end < header_end &&
             !(line_end + 1 < header_end && output[line_end] == '\r' &&
               output[line_end + 1] == '\n'))
        line_end++;
      if (line_end >= header_end)
        line_end = header_end;
      colon = line_start;
      while (colon < line_end && output[colon] != ':')
        colon++;
      if (colon == line_start || colon + 2 > line_end ||
          output[colon + 1] != ' ')
        return 0;
      for (i = line_start; i < colon; i++) {
        if (!isalnum((unsigned char)output[i]) && output[i] != '-')
          return 0;
      }

      if (header_name_is(output + line_start, colon - line_start,
                         "content-length")) {
        size_t value = 0;

        if (have_content_length || colon + 2 == line_end)
          return 0;
        for (i = colon + 2; i < line_end; i++) {
          unsigned int digit;

          if (!isdigit((unsigned char)output[i]))
            return 0;
          digit = (unsigned int)(output[i] - '0');
          if (value > (LSP_FRAME_BYTES - digit) / 10)
            return 0;
          value = value * 10 + digit;
        }
        content_length = value;
        have_content_length = 1;
      }
      line_start = line_end + 2;
    }

    if (!have_content_length || content_length > LSP_FRAME_BYTES)
      return 0;
    frame_start = header_end + 4;
    if (content_length > len - frame_start)
      return 0;
    frame_start += content_length;
  }
  return frame_start == len;
}

/* Custom print function that captures output. */
static int wasm_print(lua_State *L) {
  LusState *state = (LusState *)lua_touserdata(L, lua_upvalueindex(1));
  int n = lua_gettop(L);
  int i;

  for (i = 1; i <= n; i++) {
    size_t len;
    const char *s = luaL_tolstring(L, i, &len);

    if (i > 1)
      output_append(state, "\t", 1);
    output_append(state, s, len);
    lua_pop(L, 1);
  }
  output_append(state, "\n", 1);
  return 0;
}

/* Capture complete Content-Length framed messages from the LSP. */
static int wasm_io_write(lua_State *L) {
  LusState *state = (LusState *)lua_touserdata(L, lua_upvalueindex(1));
  int n = lua_gettop(L);
  int i;

  for (i = 1; i <= n; i++) {
    size_t len;
    const char *s = luaL_tolstring(L, i, &len);
    output_append(state, s, len);
    lua_pop(L, 1);
  }
  lua_getglobal(L, "io");
  lua_getfield(L, -1, "stdout");
  lua_remove(L, -2);
  return 1;
}

static int wasm_stream_write(lua_State *L) {
  LusState *state = (LusState *)lua_touserdata(L, lua_upvalueindex(1));
  int is_diagnostic = lua_toboolean(L, lua_upvalueindex(2));
  int n = lua_gettop(L);
  int i;

  luaL_checktype(L, 1, LUA_TTABLE);
  if (is_diagnostic && state->suppress_diagnostics) {
    lua_settop(L, 1);
    return 1;
  }
  for (i = 2; i <= n; i++) {
    size_t len;
    const char *s = luaL_tolstring(L, i, &len);

    output_append(state, s, len);
    lua_pop(L, 1);
  }
  lua_settop(L, 1);
  return 1;
}

static int wasm_io_flush(lua_State *L) {
  (void)L;
  return 0;
}

static int wasm_io_read(lua_State *L) {
  (void)L;
  lua_pushnil(L);
  return 1;
}

static int wasm_stream_flush(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_settop(L, 0);
  lua_pushboolean(L, 1);
  return 1;
}

static void push_capture_stream(LusState *state, int is_diagnostic) {
  lua_State *L = state->L;

  lua_newtable(L);
  lua_pushlightuserdata(L, state);
  lua_pushboolean(L, is_diagnostic);
  lua_pushcclosure(L, wasm_stream_write, 2);
  lua_setfield(L, -2, "write");
  lua_pushcfunction(L, wasm_stream_flush);
  lua_setfield(L, -2, "flush");
}

static void wasm_warning(void *ud, const char *message, int tocont) {
  LusState *state = (LusState *)ud;

  if (!tocont && message[0] == '@') {
    if (strcmp(message + 1, "on") == 0)
      state->warnings_enabled = 1;
    else if (strcmp(message + 1, "off") == 0)
      state->warnings_enabled = 0;
    return;
  }
  if (!state->warnings_enabled)
    return;
  if (state->suppress_diagnostics)
    return;
  if (!state->warning_continues)
    output_append(state, "Lua warning: ", sizeof("Lua warning: ") - 1);
  output_append(state, message, strlen(message));
  if (tocont)
    state->warning_continues = 1;
  else {
    output_append(state, "\n", 1);
    state->warning_continues = 0;
  }
}

static void setup_io_overrides(LusState *state) {
  lua_State *L = state->L;

  lua_getglobal(L, "io");
  push_capture_stream(state, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -3, "stdout");
  lua_setfield(L, LUA_REGISTRYINDEX, "_IO_output");
  push_capture_stream(state, 1);
  lua_setfield(L, -2, "stderr");
  lua_pushlightuserdata(L, state);
  lua_pushcclosure(L, wasm_io_write, 1);
  lua_setfield(L, -2, "write");
  lua_pushcfunction(L, wasm_io_flush);
  lua_setfield(L, -2, "flush");
  lua_pushcfunction(L, wasm_io_read);
  lua_setfield(L, -2, "read");
  lua_pop(L, 1);
}

static int wasm_debug_debug(lua_State *L) {
  return luaL_error(L, "debug.debug is unavailable in WebAssembly");
}

static void setup_debug_overrides(LusState *state) {
  lua_State *L = state->L;

  lua_getglobal(L, "debug");
  lua_pushcfunction(L, wasm_debug_debug);
  lua_setfield(L, -2, "debug");
  lua_pop(L, 1);
}

LusState *lus_create(void) {
  LusState *state = (LusState *)calloc(1, sizeof(LusState));

  luaAP_initwasmconsole();
  if (!state)
    return NULL;
  if (!output_reserve(state, 256)) {
    free(state);
    return NULL;
  }
  state->output[0] = '\0';
  state->L = luaL_newstate();
  if (!state->L) {
    free(state->output);
    free(state);
    return NULL;
  }

  luaL_openlibs(state->L);
  if (luaL_dostring(state->L,
                    "package.path = '/?.lus;/?/init.lus;' .. package.path") !=
      LUA_OK) {
    lua_close(state->L);
    free(state->output);
    free(state);
    return NULL;
  }
  lua_pushlightuserdata(state->L, state);
  lua_pushcclosure(state->L, wasm_print, 1);
  lua_setglobal(state->L, "print");
  state->warnings_enabled = 1;
  lua_setwarnf(state->L, wasm_warning, state);
  setup_io_overrides(state);
  setup_debug_overrides(state);
  return state;
}

const char *lus_execute_bytes(LusState *state, const char *code,
                              size_t code_len) {
  size_t marker_len = sizeof(EXEC_TRUNCATION_MESSAGE) - 1;
  char *expr_code;
  int status;

  if (!state || !state->L || !code)
    return "Error: Invalid state";
  state->suppress_diagnostics = 0;
  lua_settop(state->L, 0);
  output_reset(state, EXEC_OUTPUT_BYTES - marker_len);

  if (code_len <= (size_t)-1 - 8)
    expr_code = (char *)malloc(code_len + 8);
  else
    expr_code = NULL;
  if (expr_code) {
    memcpy(expr_code, "return ", 7);
    memcpy(expr_code + 7, code, code_len);
    expr_code[code_len + 7] = '\0';
    status = luaL_loadbufferx(state->L, expr_code, code_len + 7,
                              "=(playground expression)", "t");
    free(expr_code);

    if (status == LUA_OK) {
      status = lua_pcall(state->L, 0, LUA_MULTRET, 0);
      if (status == LUA_OK) {
        int nresults = lua_gettop(state->L);

        if (nresults > 0) {
          lua_getglobal(state->L, "print");
          lua_insert(state->L, 1);
          status = lua_pcall(state->L, nresults, 0, 0);
          if (status != LUA_OK)
            goto handle_error;
        }
        return finish_execution_output(state);
      }
      goto handle_error;
    }
    lua_settop(state->L, 0);
  }

  status = luaL_loadbufferx(state->L, code, code_len, "=(playground)", "t");
  if (status != LUA_OK)
    goto handle_error;
  status = lua_pcall(state->L, 0, LUA_MULTRET, 0);
  if (status != LUA_OK)
    goto handle_error;
  lua_settop(state->L, 0);
  return finish_execution_output(state);

handle_error: {
  const char *err = lua_tostring(state->L, -1);

  if (err)
    output_append(state, err, strlen(err));
  lua_settop(state->L, 0);
  return finish_execution_output(state);
}
}

const char *lus_execute(LusState *state, const char *code) {
  if (!code)
    return "Error: Invalid state";
  return lus_execute_bytes(state, code, strlen(code));
}

const char *lus_load_lsp_bytes(LusState *state, const char *source,
                               size_t source_len) {
  int status;

  if (!state || !state->L || !source)
    return "Error: Invalid state";
  state->lsp_loaded = 0;
  state->suppress_diagnostics = 1;
  lua_settop(state->L, 0);
  output_reset(state, (size_t)-1);

  status = luaL_loadbufferx(state->L, source, source_len,
                            "=@/lus-language/wasm.lus", "t");
  if (status == LUA_OK)
    status = lua_pcall(state->L, 0, 0, 0);
  state->suppress_diagnostics = 0;
  if (status != LUA_OK) {
    const char *err = lua_tostring(state->L, -1);

    if (err)
      output_append(state, err, strlen(err));
    lua_settop(state->L, 0);
    return state->output;
  }

  lua_getglobal(state->L, "_lsp_handle");
  if (!lua_isfunction(state->L, -1)) {
    lua_settop(state->L, 0);
    return output_force(state, "_lsp_handle not defined", 23);
  }
  lua_pop(state->L, 1);
  lua_getglobal(state->L, "_lsp_handle_frame");
  if (!lua_isfunction(state->L, -1)) {
    lua_settop(state->L, 0);
    return output_force(state, "_lsp_handle_frame not defined", 29);
  }
  lua_settop(state->L, 0);

  state->lsp_loaded = 1;
  return "";
}

const char *lus_load_lsp(LusState *state, const char *source) {
  if (!source)
    return "Error: Invalid state";
  return lus_load_lsp_bytes(state, source, strlen(source));
}

static const char *call_lsp_handler(LusState *state, const char *handler,
                                    const char *input, size_t input_len) {
  int status;

  lua_settop(state->L, 0);
  output_reset(state, LSP_OUTPUT_BYTES);
  lua_getglobal(state->L, handler);
  lua_pushlstring(state->L, input, input_len);
  state->suppress_diagnostics = 1;
  status = lua_pcall(state->L, 1, 0, 0);
  state->suppress_diagnostics = 0;
  if (status != LUA_OK) {
    lua_settop(state->L, 0);
    return set_lsp_error(state, -32603, "LSP dispatch failed");
  }
  lua_settop(state->L, 0);

  if (state->output_oom)
    return set_lsp_error(state, -32603, "LSP output allocation failed");
  if (state->output_overflow ||
      !validate_lsp_output(state->output, state->output_len))
    return set_lsp_error(state, -32603, "Invalid LSP output frame");
  return state->output;
}

const char *lus_handle_message_bytes(LusState *state, const char *json_input,
                                     size_t input_len) {
  if (!state || !state->L || !state->lsp_loaded || !json_input)
    return "";
  if (input_len > LSP_FRAME_BYTES)
    return set_lsp_error(state, -32700, "JSON-RPC body exceeds 16 MiB");
  return call_lsp_handler(state, "_lsp_handle", json_input, input_len);
}

const char *lus_handle_message(LusState *state, const char *json_input) {
  if (!json_input)
    return "";
  return lus_handle_message_bytes(state, json_input, strlen(json_input));
}

const char *lus_handle_frame_bytes(LusState *state, const char *frame,
                                   size_t input_len) {
  if (!state || !state->L || !state->lsp_loaded || !frame)
    return "";
  if (input_len > LSP_FRAME_BYTES + LSP_HEADER_BYTES)
    return set_lsp_error(state, -32700, "LSP frame exceeds 16 MiB");
  return call_lsp_handler(state, "_lsp_handle_frame", frame, input_len);
}

const char *lus_handle_frame(LusState *state, const char *frame) {
  if (!frame)
    return "";
  return lus_handle_frame_bytes(state, frame, strlen(frame));
}

size_t lus_output_length(const LusState *state) {
  return state ? state->output_len : 0;
}

void lus_destroy(LusState *state) {
  if (!state)
    return;
  if (state->L)
    lua_close(state->L);
  free(state->output);
  free(state);
}
