---
name: "lus_rawequal"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_rawequal(lus_State *L, int idx1, int idx2)"
params:
  - name: L
    type: "lus_State*"
  - name: idx1
    type: "int"
  - name: idx2
    type: "int"
returns:
  - type: "int"
---

Returns 1 when the values at the two indices are primitively equal and 0 otherwise. It calls no `__eq` metamethod. An index that names no value gives 0.
