---
name: lua_isthread
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_isthread(L,n) (lua_type(L,(n)) == LUA_TTHREAD)"
---

Returns 1 if the value at the given index is a thread.
