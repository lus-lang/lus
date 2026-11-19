---
name: lua_Reader
header: lua.h
kind: type
since: 0.1.0
stability: stable
origin: lua
signature: "typedef const char *(*lua_Reader)(lua_State *L, void *ud, size_t *sz);"
---

The reader function used by `lua_load`.
