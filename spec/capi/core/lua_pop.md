---
name: lua_pop
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_pop(L,n) lua_settop(L, -(n)-1)"
---

Pops `n` elements from the stack.
