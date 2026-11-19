---
name: luaL_checkudata
header: lauxlib.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "void *luaL_checkudata (lua_State *L, int ud, const char *tname)"
params:
  - name: L
    type: "lua_State*"
  - name: ud
    type: int
  - name: tname
    type: "const char*"
returns:
  - type: "void*"
---


