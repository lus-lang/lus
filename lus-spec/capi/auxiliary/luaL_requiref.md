---
name: luaL_requiref
header: lauxlib.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "void luaL_requiref (lua_State *L, const char *modname, lua_CFunction openf, int glb)"
params:
  - name: L
    type: "lua_State*"
  - name: modname
    type: "const char*"
  - name: openf
    type: lua_CFunction
  - name: glb
    type: int
---


