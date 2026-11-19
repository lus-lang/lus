#ifndef lus_wasm_h
#define lus_wasm_h

#include <stddef.h>

typedef struct LusState LusState;

LusState *lus_create(void);
const char *lus_execute(LusState *state, const char *code);
const char *lus_execute_bytes(LusState *state, const char *code,
                              size_t code_len);
const char *lus_load_lsp(LusState *state, const char *source);
const char *lus_load_lsp_bytes(LusState *state, const char *source,
                               size_t source_len);
const char *lus_handle_message(LusState *state, const char *json_input);
const char *lus_handle_message_bytes(LusState *state, const char *json_input,
                                     size_t input_len);
const char *lus_handle_frame(LusState *state, const char *frame);
const char *lus_handle_frame_bytes(LusState *state, const char *frame,
                                   size_t input_len);
size_t lus_output_length(const LusState *state);
void lus_destroy(LusState *state);

#endif
