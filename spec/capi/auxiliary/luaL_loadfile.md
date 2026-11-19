---
name: luaL_loadfile
header: lauxlib.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define luaL_loadfile(L,f) luaL_loadfilex(L,f,NULL)"
---

Loads a file as a Lua chunk (macro for `luaL_loadfilex` with NULL mode).
