---
name: lua_pushliteral
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_pushliteral(L,s) lua_pushstring(L, \"\" s)"
---

Pushes a literal string onto the stack.
