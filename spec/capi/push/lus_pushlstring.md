---
name: "lus_pushlstring"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_pushlstring(lus_State *L, const char *s, size_t len)"
params:
  - name: L
    type: "lus_State*"
  - name: s
    type: "const char*"
  - name: len
    type: "size_t"
returns:
  - type: "int"
    name: status
---

Pushes a copy of the first `len` bytes of `s` as a string and returns `LUS_OK`. The bytes can include zero bytes. `s` can be `NULL` when `len` is 0, which pushes the empty string.

Like `lus_pushstring`, it requires well formed WTF-8, returns `LUS_ERRRUN` or `LUS_ERRMEM` on failure, and pushes exactly one value in every case. A vector made with `lus_pushbytes` holds arbitrary bytes.
