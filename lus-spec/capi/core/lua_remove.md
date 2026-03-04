---
name: lua_remove
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_remove(L,idx) (lua_rotate(L,(idx),-1), lua_pop(L,1))"
---

Removes the element at the given valid index, shifting down elements above.
