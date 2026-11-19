---
name: lua_pushglobaltable
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_pushglobaltable(L) ((void)lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS))"
---

Pushes the global environment table onto the stack.
