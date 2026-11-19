---
name: lua_isnil
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_isnil(L,n) (lua_type(L,(n)) == LUA_TNIL)"
---

Returns 1 if the value at the given index is nil.
