---
name: luaL_checklstring
header: lauxlib.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "const char *luaL_checklstring (lua_State *L, int arg, size_t *l)"
params:
  - name: L
    type: "lua_State*"
  - name: arg
    type: int
  - name: l
    type: "size_t*"
returns:
  - type: "const char*"
---


