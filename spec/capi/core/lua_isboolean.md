---
name: lua_isboolean
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_isboolean(L,n) (lua_type(L,(n)) == LUA_TBOOLEAN)"
---

Returns 1 if the value at the given index is a boolean.
