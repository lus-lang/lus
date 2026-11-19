---
name: "lus_isfunction"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_isfunction(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
---

Returns 1 when the value at `idx` is a function, written either in Lus or in C, and 0 otherwise. A table or userdata with a `__call` metamethod gives 0.
