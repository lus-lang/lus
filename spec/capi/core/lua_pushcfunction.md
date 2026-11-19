---
name: lua_pushcfunction
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_pushcfunction(L,f) lua_pushcclosure(L,(f),0)"
---

Pushes a C function onto the stack (macro for `lua_pushcclosure` with 0 upvalues).
