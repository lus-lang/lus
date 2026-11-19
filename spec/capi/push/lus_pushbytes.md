---
name: "lus_pushbytes"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_pushbytes(lus_State *L, const void *p, size_t len)"
params:
  - name: L
    type: "lus_State*"
  - name: p
    type: "const void*"
  - name: len
    type: "size_t"
returns:
  - type: "int"
    name: status
---

Pushes a new vector that holds a copy of `len` bytes from `p`, or `len` zero bytes when `p` is `NULL`, and returns `LUS_OK`. The bytes can be anything. On failure it returns `LUS_ERRMEM` and pushes the error value in place of the vector.

`lus_tobytes` reads and writes the contents of a vector.
