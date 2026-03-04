---
name: luaL_Stream
header: lauxlib.h
kind: type
since: 0.1.0
stability: stable
origin: lua
signature: "typedef struct luaL_Stream { FILE *f; lua_CFunction closef; } luaL_Stream;"
---

The internal structure used by the standard I/O library for file handles.
