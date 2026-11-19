---
name: lua_getstack
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int lua_getstack (lua_State *L, int level, lua_Debug *ar)"
params:
  - name: L
    type: "lua_State*"
  - name: level
    type: int
  - name: ar
    type: "lua_Debug*"
returns:
  - type: int
---


