---
name: lua_upvalueid
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "void *lua_upvalueid (lua_State *L, int fidx, int n)"
params:
  - name: L
    type: "lua_State*"
  - name: fidx
    type: int
  - name: n
    type: int
returns:
  - type: "void*"
---


