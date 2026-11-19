---
name: "lus_tolight"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void *lus_tolight(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "void*"
---

Returns the pointer of a light value, and `NULL` for every other type, userdata included.
