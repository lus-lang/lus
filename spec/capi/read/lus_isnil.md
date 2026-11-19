---
name: "lus_isnil"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_isnil(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
---

Returns 1 when the value at `idx` is nil and 0 otherwise. An index that names no value also gives 1.
