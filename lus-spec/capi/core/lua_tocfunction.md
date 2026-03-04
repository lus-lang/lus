---
name: lua_tocfunction
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "lua_CFunction lua_tocfunction (lua_State *L, int idx)"
params:
  - name: L
    type: "lua_State*"
  - name: idx
    type: int
returns:
  - type: lua_CFunction
---


