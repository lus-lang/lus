---
name: lua_newstate
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "lua_State *lua_newstate (lua_Alloc f, void *ud, unsigned seed)"
params:
  - name: f
    type: lua_Alloc
  - name: ud
    type: "void*"
  - name: seed
    type: unsigned
returns:
  - type: "lua_State*"
---


