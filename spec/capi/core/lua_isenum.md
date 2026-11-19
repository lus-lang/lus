---
name: lua_isenum
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lus
signature: "#define lua_isenum(L,n) (lua_type(L,(n)) == LUA_TENUM)"
---

Returns 1 if the value at the given index is an enum.
