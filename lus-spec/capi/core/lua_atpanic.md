---
name: lua_atpanic
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "lua_CFunction lua_atpanic (lua_State *L, lua_CFunction panicf)"
params:
  - name: L
    type: "lua_State*"
  - name: panicf
    type: lua_CFunction
returns:
  - type: lua_CFunction
---


