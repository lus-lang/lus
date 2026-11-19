---
name: "lus_touserdata"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void *lus_touserdata(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "void*"
---

Returns the pointer of a light value or the data block of a userdata, and `NULL` for every other type. The data block lives as long as its userdata. `lus_toudata` additionally checks the type of a userdata through its metatable.
