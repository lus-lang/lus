---
name: lua_islightuserdata
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_islightuserdata(L,n) (lua_type(L,(n)) == LUA_TLIGHTUSERDATA)"
---

Returns 1 if the value at the given index is a light userdata.
