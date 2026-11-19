---
name: lua_isnone
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_isnone(L,n) (lua_type(L,(n)) == LUA_TNONE)"
---

Returns 1 if the given index is not valid.
