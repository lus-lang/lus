---
name: lua_isvector
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lus
signature: "#define lua_isvector(L,n) (lua_type(L,(n)) == LUA_TVECTOR)"
---

Returns 1 if the value at the given index is a vector.
