---
name: "lus_tobytes"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "unsigned char *lus_tobytes(lus_State *L, int idx, size_t *len)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
  - name: len
    type: "size_t*"
returns:
  - type: "unsigned char*"
---

Returns the contents of the vector at `idx` and stores its length in `len` when `len` is not `NULL`. Every other type gives `NULL`. An empty vector gives a valid pointer with a length of 0.

The bytes can be changed in place, and scripts see the change. The pointer stays valid until the vector is resized or collected, so a host keeps the vector on the stack or in a reference while it uses the pointer.
