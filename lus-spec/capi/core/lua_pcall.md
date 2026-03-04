---
name: lua_pcall
header: lua.h
kind: macro
since: 0.1.0
stability: deprecated
origin: lua
signature: "#define lua_pcall(L,n,r,f) lua_pcallk(L,(n),(r),(f),0,NULL)"
---

**Deprecated.** Calls a function in protected mode.
