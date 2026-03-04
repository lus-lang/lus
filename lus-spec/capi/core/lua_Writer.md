---
name: lua_Writer
header: lua.h
kind: type
since: 0.1.0
stability: stable
origin: lua
signature: "typedef int (*lua_Writer)(lua_State *L, const void *p, size_t sz, void *ud);"
---

The writer function used by `lua_dump`.
