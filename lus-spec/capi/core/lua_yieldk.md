---
name: lua_yieldk
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int lua_yieldk (lua_State *L, int nresults, lua_KContext ctx, lua_KFunction k)"
params:
  - name: L
    type: "lua_State*"
  - name: nresults
    type: int
  - name: ctx
    type: lua_KContext
  - name: k
    type: lua_KFunction
returns:
  - type: int
---


