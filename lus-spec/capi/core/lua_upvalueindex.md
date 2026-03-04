---
name: lua_upvalueindex
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_upvalueindex(i) (LUA_REGISTRYINDEX - (i))"
---

Returns the pseudo-index for the `i`-th upvalue of a C closure.
