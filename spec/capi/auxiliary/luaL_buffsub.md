---
name: luaL_buffsub
header: lauxlib.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define luaL_buffsub(B,s) ((B)->n -= (s))"
---

Removes `s` bytes from the buffer.
