---
name: lua_register
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_register(L,n,f) (lua_pushcfunction(L,(f)), lua_setglobal(L,(n)))"
---

Sets the C function `f` as the new value of global `n`.
