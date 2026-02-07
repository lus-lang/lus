/*
** Lus WebAssembly wrapper
** Provides APIs for executing Lus code and running the LSP in the browser
*/

#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

/* Output buffer for capturing print/io.write results */
#define OUTPUT_BUFFER_SIZE (256 * 1024)

typedef struct {
  lua_State *L;
  char output[OUTPUT_BUFFER_SIZE];
  size_t output_len;
  int lsp_loaded;
} LusState;

/* Append raw data to the output buffer */
static void output_append(LusState *state, const char *data, size_t len) {
  if (state->output_len + len < OUTPUT_BUFFER_SIZE - 1) {
    memcpy(state->output + state->output_len, data, len);
    state->output_len += len;
    state->output[state->output_len] = '\0';
  }
}

/* Custom print function that captures output */
static int wasm_print(lua_State *L) {
  LusState *state = (LusState *)lua_touserdata(L, lua_upvalueindex(1));
  int n = lua_gettop(L);
  int i;

  for (i = 1; i <= n; i++) {
    size_t len;
    const char *s = luaL_tolstring(L, i, &len);

    if (i > 1) {
      output_append(state, "\t", 1);
    }

    output_append(state, s, len);
    lua_pop(L, 1); /* pop result of luaL_tolstring */
  }

  output_append(state, "\n", 1);
  return 0;
}

/*
** Custom io.write replacement that captures output to the buffer.
** This is critical for LSP: the language server uses io.write to send
** Content-Length-delimited JSON-RPC messages.
*/
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

  /* Return the io table for chaining */
  lua_getglobal(L, "io");
  return 1;
}

/* Custom io.flush replacement (no-op in WASM) */
static int wasm_io_flush(lua_State *L) {
  (void)L;
  return 0;
}

/* Custom io.read replacement (returns nil -- messages are fed directly) */
static int wasm_io_read(lua_State *L) {
  (void)L;
  lua_pushnil(L);
  return 1;
}

/* Set up io overrides for LSP mode */
static void setup_io_overrides(LusState *state) {
  lua_State *L = state->L;

  /* Override io.write */
  lua_getglobal(L, "io");
  lua_pushlightuserdata(L, state);
  lua_pushcclosure(L, wasm_io_write, 1);
  lua_setfield(L, -2, "write");

  /* Override io.flush */
  lua_pushcfunction(L, wasm_io_flush);
  lua_setfield(L, -2, "flush");

  /* Override io.read */
  lua_pushcfunction(L, wasm_io_read);
  lua_setfield(L, -2, "read");

  lua_pop(L, 1); /* pop io table */
}

/* Create a new Lus state */
LusState *lus_create(void) {
  LusState *state = (LusState *)malloc(sizeof(LusState));
  if (!state)
    return NULL;

  state->L = luaL_newstate();
  if (!state->L) {
    free(state);
    return NULL;
  }

  state->output[0] = '\0';
  state->output_len = 0;
  state->lsp_loaded = 0;

  /* Open all standard libraries */
  luaL_openlibs(state->L);

  /* Override print to capture output */
  lua_pushlightuserdata(state->L, state);
  lua_pushcclosure(state->L, wasm_print, 1);
  lua_setglobal(state->L, "print");

  return state;
}

/* Execute Lus code and return output (or error message) */
const char *lus_execute(LusState *state, const char *code) {
  if (!state || !state->L)
    return "Error: Invalid state";

  /* Clear output buffer */
  state->output[0] = '\0';
  state->output_len = 0;

  /* Try to load as expression first (prepend "return ") */
  size_t code_len = strlen(code);
  char *expr_code = (char *)malloc(code_len + 8);
  if (expr_code) {
    strcpy(expr_code, "return ");
    strcat(expr_code, code);

    int status = luaL_loadstring(state->L, expr_code);
    free(expr_code);

    if (status == LUA_OK) {
      /* Expression loaded, execute it */
      status = lua_pcall(state->L, 0, LUA_MULTRET, 0);
      if (status == LUA_OK) {
        /* Print any return values */
        int nresults = lua_gettop(state->L);
        if (nresults > 0) {
          lua_getglobal(state->L, "print");
          lua_insert(state->L, 1);
          lua_pcall(state->L, nresults, 0, 0);
        }
        return state->output;
      }
      /* Execution failed, get error */
      goto handle_error;
    }

    /* Not a valid expression, clear stack and try as statement */
    lua_settop(state->L, 0);
  }

  /* Load as statement */
  int status = luaL_loadstring(state->L, code);
  if (status != LUA_OK) {
    goto handle_error;
  }

  /* Execute */
  status = lua_pcall(state->L, 0, LUA_MULTRET, 0);
  if (status != LUA_OK) {
    goto handle_error;
  }

  return state->output;

handle_error: {
  const char *err = lua_tostring(state->L, -1);
  if (err && state->output_len + strlen(err) < OUTPUT_BUFFER_SIZE - 1) {
    strcpy(state->output + state->output_len, err);
  }
  lua_pop(state->L, 1);
  return state->output;
}
}

/*
** Load the LSP server code.
** Executes the provided Lus source which should set up the global
** _lsp_handle function for processing messages.
** Returns empty string on success, or error message on failure.
*/
const char *lus_load_lsp(LusState *state, const char *source) {
  if (!state || !state->L)
    return "Error: Invalid state";

  /* Set up io overrides for LSP mode */
  setup_io_overrides(state);

  /* Clear output buffer */
  state->output[0] = '\0';
  state->output_len = 0;

  /* Load and execute the LSP setup script */
  int status = luaL_loadstring(state->L, source);
  if (status != LUA_OK) {
    const char *err = lua_tostring(state->L, -1);
    if (err) {
      output_append(state, err, strlen(err));
    }
    lua_pop(state->L, 1);
    return state->output;
  }

  status = lua_pcall(state->L, 0, 0, 0);
  if (status != LUA_OK) {
    const char *err = lua_tostring(state->L, -1);
    if (err) {
      output_append(state, err, strlen(err));
    }
    lua_pop(state->L, 1);
    return state->output;
  }

  /* Verify that _lsp_handle is defined */
  lua_getglobal(state->L, "_lsp_handle");
  if (!lua_isfunction(state->L, -1)) {
    lua_pop(state->L, 1);
    output_append(state, "_lsp_handle not defined", 23);
    return state->output;
  }
  lua_pop(state->L, 1);

  state->lsp_loaded = 1;
  return "";
}

/*
** Handle a single LSP message.
** Takes a JSON string, calls _lsp_handle(json), captures all io.write
** output (Content-Length-delimited LSP responses/notifications).
** Returns the captured output (may contain multiple LSP messages).
*/
const char *lus_handle_message(LusState *state, const char *json_input) {
  if (!state || !state->L || !state->lsp_loaded)
    return "";

  /* Clear output buffer */
  state->output[0] = '\0';
  state->output_len = 0;

  /* Call _lsp_handle(json_input) */
  lua_getglobal(state->L, "_lsp_handle");
  lua_pushstring(state->L, json_input);

  int status = lua_pcall(state->L, 1, 0, 0);
  if (status != LUA_OK) {
    const char *err = lua_tostring(state->L, -1);
    if (err) {
      state->output[0] = '\0';
      state->output_len = 0;
      output_append(state, "LSP error: ", 11);
      output_append(state, err, strlen(err));
    }
    lua_pop(state->L, 1);
  }

  return state->output;
}

/* Destroy a Lus state */
void lus_destroy(LusState *state) {
  if (state) {
    if (state->L) {
      lua_close(state->L);
    }
    free(state);
  }
}
