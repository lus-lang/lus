---
name: luaL_tolstring
header: lauxlib.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "const char *luaL_tolstring (lua_State *L, int idx, size_t *len)"
params:
  - name: L
    type: "lua_State*"
  - name: idx
    type: int
  - name: len
    type: "size_t*"
returns:
  - type: "const char*"
---


