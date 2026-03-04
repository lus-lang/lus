---
name: luaL_checkoption
header: lauxlib.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int luaL_checkoption (lua_State *L, int arg, const char *def, const char *const lst[])"
params:
  - name: L
    type: "lua_State*"
  - name: arg
    type: int
  - name: def
    type: "const char*"
  - name: lst
    type: "const char *const[]"
returns:
  - type: int
---


