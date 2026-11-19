---
name: luaL_optlstring
header: lauxlib.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "const char *luaL_optlstring (lua_State *L, int arg, const char *def, size_t *l)"
params:
  - name: L
    type: "lua_State*"
  - name: arg
    type: int
  - name: def
    type: "const char*"
  - name: l
    type: "size_t*"
returns:
  - type: "const char*"
---


