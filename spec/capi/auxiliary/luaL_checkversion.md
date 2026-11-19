---
name: luaL_checkversion
header: lauxlib.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define luaL_checkversion(L) luaL_checkversion_(L, LUA_VERSION_NUM, LUAL_NUMSIZES)"
---

Checks that the code making the call and the Lua library being called are using the same version of Lua and compatible numeric types.
