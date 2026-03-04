---
name: lua_callk
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "void lua_callk (lua_State *L, int nargs, int nresults, lua_KContext ctx, lua_KFunction k)"
params:
  - name: L
    type: "lua_State*"
  - name: nargs
    type: int
  - name: nresults
    type: int
  - name: ctx
    type: lua_KContext
  - name: k
    type: lua_KFunction
---


