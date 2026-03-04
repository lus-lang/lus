---
name: lua_istable
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_istable(L,n) (lua_type(L,(n)) == LUA_TTABLE)"
---

Returns 1 if the value at the given index is a table.
