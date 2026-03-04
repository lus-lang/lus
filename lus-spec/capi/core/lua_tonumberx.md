---
name: lua_tonumberx
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "lua_Number lua_tonumberx (lua_State *L, int idx, int *isnum)"
params:
  - name: L
    type: "lua_State*"
  - name: idx
    type: int
  - name: isnum
    type: "int*"
returns:
  - type: lua_Number
---


