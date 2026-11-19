---
name: "lus_isinteger"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_isinteger(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
---

Returns 1 when the value at `idx` is an integer and 0 otherwise. A float with an integral value, such as `3.0`, and a numeric string give 0. `lus_tointeger` accepts those.
