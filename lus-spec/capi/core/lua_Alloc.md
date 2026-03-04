---
name: lua_Alloc
header: lua.h
kind: type
since: 0.1.0
stability: stable
origin: lua
signature: "typedef void *(*lua_Alloc)(void *ud, void *ptr, size_t osize, size_t nsize);"
---

The type of the memory-allocation function used by Lua states.
