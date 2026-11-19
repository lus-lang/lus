---
name: luaL_Reg
header: lauxlib.h
kind: type
since: 0.1.0
stability: stable
origin: lua
signature: "typedef struct luaL_Reg { const char *name; lua_CFunction func; } luaL_Reg;"
---

Type for arrays of functions to be registered with `luaL_setfuncs`.
