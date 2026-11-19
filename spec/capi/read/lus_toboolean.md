---
name: "lus_toboolean"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_toboolean(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
---

Returns 0 for nil and false and 1 for every other value, following the truth rule of conditions in Lus. An index that names no value gives 0.
