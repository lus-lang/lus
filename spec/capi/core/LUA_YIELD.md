---
name: lua_yield
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_yield(L,n) lua_yieldk(L,(n),0,NULL)"
---

Yields a coroutine (macro for `lua_yieldk` with no continuation).
