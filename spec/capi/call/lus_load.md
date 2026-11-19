---
name: "lus_load"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_load(lus_State *L, const char *buf, size_t len, const char *chunkname)"
params:
  - name: L
    type: "lus_State*"
  - name: buf
    type: "const char*"
  - name: len
    type: "size_t"
  - name: chunkname
    type: "const char*"
returns:
  - type: "int"
    name: status
---

Compiles the `len` bytes at `buf` and pushes the resulting function, then returns `LUS_OK`. The buffer holds either source text or a binary chunk, and the call tells them apart by their first bytes. The function runs with the global table as its environment when it is called. Loading from C needs no permission.

`chunkname` names the chunk in error messages and tracebacks. A name of the form `"@path"` names a file, and messages show `path`. A name of the form `"=name"` shows `name` as written. `NULL` means `"=(load)"`.

On a syntax error or a malformed binary chunk, the call returns `LUS_ERRSYNTAX` and pushes the message, such as `config:3: unexpected symbol near '='`. When memory runs out it returns `LUS_ERRMEM`. The call pushes exactly one value in every case.

```c
const char *src = "return 6 * 7";
if (lus_load(L, src, strlen(src), "=answer") != LUS_OK) {
  fprintf(stderr, "%s\n", lus_tostring(L, -1, NULL));
  lus_pop(L, 1);
}
```
