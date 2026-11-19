---
name: luaL_getmetatable
header: lauxlib.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define luaL_getmetatable(L,n) (lua_getfield(L,LUA_REGISTRYINDEX,(n)))"
---

Pushes onto the stack the metatable associated with the name `n` in the registry.
