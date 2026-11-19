---
name: luaL_dofile
header: lauxlib.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define luaL_dofile(L,fn) (luaL_loadfile(L,fn) || lua_pcall(L,0,LUA_MULTRET,0))"
---

Loads and runs the given file.
