---
name: lua_getextraspace
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_getextraspace(L) ((void *)((char *)(L) - LUA_EXTRASPACE))"
---

Returns a pointer to a raw memory area associated with the given Lua state.
