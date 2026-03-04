---
name: lua_getfield
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int lua_getfield (lua_State *L, int idx, const char *k)"
params:
  - name: L
    type: "lua_State*"
  - name: idx
    type: int
  - name: k
    type: "const char*"
returns:
  - type: int
---


