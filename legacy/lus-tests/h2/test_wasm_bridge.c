#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lus_wasm.h"

#define LSP_LIMIT (16u * 1024u * 1024u)
#define OUTPUT_LIMIT (256u * 1024u)
#define LARGE_SOURCE_BYTES (2u * 1024u * 1024u)

static int failures = 0;

static void check(int condition, const char *message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message);
    failures++;
  }
}

static void check_frame_body(const char *frame, const char *body,
                             size_t body_len) {
  char header[64];
  int header_len =
      snprintf(header, sizeof(header), "Content-Length: %zu\r\n\r\n", body_len);

  check(header_len > 0, "frame header formats");
  if (header_len <= 0)
    return;
  check(memcmp(frame, header, (size_t)header_len) == 0,
        "frame has the declared length");
  check(memcmp(frame + header_len, body, body_len) == 0,
        "frame preserves every body byte");
  check(frame[header_len + body_len] == '\0', "frame ends at its body");
}

int main(void) {
  static const char echo_server[] =
      "global io, _lsp_handle, _lsp_handle_frame\n"
      "function _lsp_handle(body)\n"
      "  io.write('Content-Length: ' .. #body .. '\\r\\n\\r\\n' .. body)\n"
      "end\n"
      "function _lsp_handle_frame(frame) io.write(frame) end\n";
  static const char multiple_server[] =
      "global io, _lsp_handle, _lsp_handle_frame\n"
      "function _lsp_handle(body)\n"
      "  local frame = 'Content-Length: ' .. #body .. '\\r\\n\\r\\n' .. body\n"
      "  io.write(frame)\n"
      "  io.write(frame)\n"
      "end\n"
      "function _lsp_handle_frame(frame) io.write(frame) end\n";
  static const char malformed_server[] =
      "global io, _lsp_handle, _lsp_handle_frame\n"
      "function _lsp_handle(body) io.write('broken') end\n"
      "function _lsp_handle_frame(frame) io.write(frame) end\n";
  static const char diagnostic_server[] =
      "global io, _lsp_handle, _lsp_handle_frame\n"
      "function _lsp_handle(body) io.stderr:write('diagnostic') end\n"
      "function _lsp_handle_frame(frame) io.stderr:write('diagnostic') end\n";
  static const char small_body[] = "{\"jsonrpc\":\"2.0\"}";
  static const char small_frame[] =
      "Content-Length: 17\r\n\r\n{\"jsonrpc\":\"2.0\"}";
  LusState *state = lus_create();
  const char *output;
  char *large_body;
  char *large_source;

  check(state != NULL, "bridge state creates");
  if (!state)
    return 1;

  output = lus_execute(state, "string.rep('x', 300 * 1024)");
  check(strlen(output) == OUTPUT_LIMIT,
        "execution output is capped at 256 KiB");
  check(strstr(output, "[Output truncated at 256 KiB.]") != NULL,
        "execution truncation is visible");
  check(strcmp(lus_execute(state, "2 + 2"), "4\n") == 0,
        "execution clears prior stack results");

  output = lus_execute(
      state,
      "local ignored = 0\nio.write('left' .. string.char(0) .. 'right')");
  check(lus_output_length(state) == 10,
        "execution reports output bytes across an embedded NUL");
  check(memcmp(output, "left\0right", 10) == 0,
        "execution preserves output bytes across an embedded NUL");

  output = lus_execute(
      state, "local ignored = 0\nio.write(string.rep('w', 300 * 1024))");
  check(lus_output_length(state) == OUTPUT_LIMIT,
        "io.write output is capped at 256 KiB");
  check(memcmp(output + OUTPUT_LIMIT -
                   (sizeof("\n[Output truncated at 256 KiB.]\n") - 1),
               "\n[Output truncated at 256 KiB.]\n",
               sizeof("\n[Output truncated at 256 KiB.]\n") - 1) == 0,
        "io.write truncation is visible");

  output = lus_execute(
      state, "local ignored = 0\nio.stderr:write(string.rep('e', 300 * 1024))");
  check(lus_output_length(state) == OUTPUT_LIMIT,
        "io.stderr output is capped at 256 KiB");
  check(memcmp(output + OUTPUT_LIMIT -
                   (sizeof("\n[Output truncated at 256 KiB.]\n") - 1),
               "\n[Output truncated at 256 KiB.]\n",
               sizeof("\n[Output truncated at 256 KiB.]\n") - 1) == 0,
        "io.stderr truncation is visible");

  output = lus_execute(state, "local ignored = 0\nwarn('captured warning')");
  check(
      lus_output_length(state) == sizeof("Lua warning: captured warning\n") - 1,
      "warnings are captured instead of reaching the host console");
  check(memcmp(output, "Lua warning: captured warning\n",
               sizeof("Lua warning: captured warning\n") - 1) == 0,
        "captured warning text is intact");

  output = lus_execute(state, "debug.debug()");
  check(strstr(output, "debug.debug is unavailable in WebAssembly") != NULL,
        "the raw debug console fails through bounded execution output");
  check(lus_output_length(state) == strlen(output),
        "the debug console error has an exact captured length");

#if defined(__EMSCRIPTEN__)
  output = lus_execute(state,
                       "local ignored = 0\n"
                       "local ok, reason = catch io.open('/dev/stdout', 'w')\n"
                       "print(ok, tostring(reason))\n"
                       "ok, reason = catch io.output('/dev/stderr')\n"
                       "print(ok, tostring(reason))");
  check(strstr(output, "host console devices are unavailable in WebAssembly") !=
            NULL,
        "reopened host console devices fail through captured output");
  check(lus_output_length(state) == strlen(output),
        "host console denial has an exact captured length");
#endif

  large_source = (char *)malloc(LARGE_SOURCE_BYTES + 1);
  check(large_source != NULL, "large execution source allocates");
  if (large_source) {
    memset(large_source, 'x', LARGE_SOURCE_BYTES);
    large_source[0] = '-';
    large_source[1] = '-';
    large_source[LARGE_SOURCE_BYTES] = '\0';
    output = lus_execute_bytes(state, large_source, LARGE_SOURCE_BYTES);
    check(output[0] == '\0', "2 MiB source executes through the byte API");
    check(strcmp(lus_execute(state, "3 + 3"), "6\n") == 0,
          "state remains reusable after a large source");

    memset(large_source, ' ', LARGE_SOURCE_BYTES);
    memcpy(large_source, "local =", sizeof("local =") - 1);
    output = lus_execute_bytes(state, large_source, LARGE_SOURCE_BYTES);
    check(output[0] != '\0', "large parse error is reported");
    check(strcmp(lus_execute(state, "4 + 4"), "8\n") == 0,
          "state remains reusable after a large parse error");
    free(large_source);
  }

  output = lus_load_lsp_bytes(state, echo_server, sizeof(echo_server) - 1);
  if (output[0] != '\0')
    fprintf(stderr, "echo LSP load error: %s\n", output);
  check(output[0] == '\0', "echo LSP loads");
  output = lus_handle_message_bytes(state, small_body, sizeof(small_body) - 1);
  if (strncmp(output, "Content-Length: 17\r\n\r\n", 22) != 0)
    fprintf(stderr, "small body output: %s\n", output);
  check_frame_body(output, small_body, sizeof(small_body) - 1);
  check(lus_output_length(state) == strlen(small_frame),
        "numeric bridge reports its exact output byte length");
  output = lus_handle_frame(state, small_frame);
  if (strcmp(output, small_frame) != 0)
    fprintf(stderr, "small frame output: %s\n", output);
  check(strcmp(output, small_frame) == 0, "canonical frame input round trips");

  large_body = (char *)malloc(LSP_LIMIT + 2);
  check(large_body != NULL, "large LSP body allocates");
  if (large_body) {
    memset(large_body, 'x', LSP_LIMIT + 1);
    large_body[LSP_LIMIT] = '\0';
    output = lus_handle_message_bytes(state, large_body, LSP_LIMIT);
    check_frame_body(output, large_body, LSP_LIMIT);
    check(lus_output_length(state) > LSP_LIMIT,
          "exact-limit numeric input preserves its framed output length");

    large_body[LSP_LIMIT] = 'x';
    large_body[LSP_LIMIT + 1] = '\0';
    output = lus_handle_message_bytes(state, large_body, LSP_LIMIT + 1);
    check(strstr(output, "JSON-RPC body exceeds 16 MiB") != NULL,
          "oversized input returns an explicit framed error");
    free(large_body);
  }

  output = lus_load_lsp(state, multiple_server);
  if (output[0] != '\0')
    fprintf(stderr, "multiple LSP load error: %s\n", output);
  check(output[0] == '\0', "multiple-frame LSP loads");
  output = lus_handle_message(state, small_body);
  check(strlen(output) == 2 * strlen(small_frame),
        "multiple complete frames survive one dispatch");
  check(memcmp(output, small_frame, strlen(small_frame)) == 0,
        "first dispatch frame is intact");
  check(strcmp(output + strlen(small_frame), small_frame) == 0,
        "second dispatch frame is intact");

  output = lus_load_lsp(state, malformed_server);
  if (output[0] != '\0')
    fprintf(stderr, "malformed LSP load error: %s\n", output);
  check(output[0] == '\0', "malformed-output LSP loads");
  output = lus_handle_message(state, small_body);
  check(strstr(output, "Invalid LSP output frame") != NULL,
        "malformed outbound data fails with a complete error frame");

  output = lus_load_lsp(state, diagnostic_server);
  check(output[0] == '\0', "diagnostic LSP loads");
  output = lus_handle_message(state, small_body);
  check(lus_output_length(state) == 0 && output[0] == '\0',
        "LSP diagnostics stay off the framed protocol channel");

  lus_destroy(state);
  if (failures) {
    fprintf(stderr, "%d WASM bridge checks failed\n", failures);
    return 1;
  }
  puts("WASM bridge checks passed");
  return 0;
}
