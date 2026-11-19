---
name: luaL_Buffer
header: lauxlib.h
kind: type
since: 0.1.0
stability: stable
origin: lua
signature: "struct luaL_Buffer { char *b; size_t size; size_t n; lua_State *L; };"
---

Type for a string buffer. A string buffer allows C code to build Lua strings piecemeal.
