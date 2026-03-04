---
name: lua_isfunction
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_isfunction(L,n) (lua_type(L,(n)) == LUA_TFUNCTION)"
---

Returns 1 if the value at the given index is a function.
