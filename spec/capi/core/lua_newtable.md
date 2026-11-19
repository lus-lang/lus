---
name: lua_newtable
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_newtable(L) lua_createtable(L, 0, 0)"
---

Creates a new empty table and pushes it onto the stack.
