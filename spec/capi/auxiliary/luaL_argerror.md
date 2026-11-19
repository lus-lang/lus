---
name: luaL_argerror
header: lauxlib.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int luaL_argerror (lua_State *L, int arg, const char *extramsg)"
params:
  - name: L
    type: "lua_State*"
  - name: arg
    type: int
  - name: extramsg
    type: "const char*"
returns:
  - type: int
---


