---
name: lua_replace
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_replace(L,idx) (lua_copy(L,-1,(idx)), lua_pop(L,1))"
---

Moves the top element into the given valid index without shifting.
