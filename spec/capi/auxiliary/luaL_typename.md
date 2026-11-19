---
name: luaL_typename
header: lauxlib.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define luaL_typename(L,i) lua_typename(L, lua_type(L,(i)))"
---

Returns the name of the type of the value at the given index.
