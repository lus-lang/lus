---
name: lua_pcall
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_pcall(L,n,r,f) lua_pcallk(L,(n),(r),(f),0,NULL)"
---

Calls a function in protected mode. It expands to `lua_pcallk` with a null continuation. Success returns `LUA_OK`. A failure returns its status code and leaves the error object on the stack.
