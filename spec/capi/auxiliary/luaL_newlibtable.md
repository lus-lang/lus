---
name: luaL_newlibtable
header: lauxlib.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define luaL_newlibtable(L,l) lua_createtable(L, 0, sizeof(l)/sizeof((l)[0]) - 1)"
---

Creates a table with a size hint for the number of entries in `l`.
