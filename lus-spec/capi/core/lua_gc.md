---
name: lua_gc
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int lua_gc (lua_State *L, int what, ...)"
params:
  - name: L
    type: "lua_State*"
  - name: what
    type: int
returns:
  - type: int
---


