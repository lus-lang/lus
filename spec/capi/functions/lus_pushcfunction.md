---
name: "lus_pushcfunction"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_pushcfunction(lus_State *L, lus_CFunction f)"
params:
  - name: L
    type: "lus_State*"
  - name: f
    type: "lus_CFunction"
returns:
  - type: "int"
    name: status
---

Pushes the C function `f` as a function value and returns `LUS_OK`. It is `lus_pushcclosure` with no upvalues. On failure it returns `LUS_ERRMEM` and pushes the error value in place of the function.
