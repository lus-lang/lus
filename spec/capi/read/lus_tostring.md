---
name: "lus_tostring"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "const char *lus_tostring(lus_State *L, int idx, size_t *len)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
  - name: len
    type: "size_t*"
returns:
  - type: "const char*"
---

Returns the bytes of the string at `idx` and stores its length in bytes in `len` when `len` is not `NULL`. Every other type, numbers included, gives `NULL`, and `lus_stringify` converts any value to a string first.

The bytes are well formed WTF-8 followed by a zero byte. A string can hold zero bytes of its own, so `len` gives its full length. The string belongs to the state, and the pointer stays valid while the string remains on the stack.
