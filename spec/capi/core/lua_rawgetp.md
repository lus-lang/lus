---
name: lua_rawgetp
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int lua_rawgetp (lua_State *L, int idx, const void *p)"
params:
  - name: L
    type: "lua_State*"
  - name: idx
    type: int
  - name: p
    type: "const void*"
returns:
  - type: int
---


