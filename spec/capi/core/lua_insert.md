---
name: lua_insert
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_insert(L,idx) lua_rotate(L,(idx),1)"
---

Moves the top element into the given valid index, shifting up elements above.
