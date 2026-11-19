---
name: lua_pushcclosure
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "void lua_pushcclosure (lua_State *L, lua_CFunction fn, int n)"
params:
  - name: L
    type: "lua_State*"
  - name: fn
    type: lua_CFunction
  - name: n
    type: int
---


