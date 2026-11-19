---
name: lus_isquery
header: lua.h
kind: macro
since: 1.7.0
stability: unstable
origin: lus
signature: "int lus_isquery (lua_State *L, int n)"
params:
  - name: L
    type: "lua_State*"
  - name: n
    type: int
---

Returns 1 when the value at index `n` is a query and 0 otherwise.
