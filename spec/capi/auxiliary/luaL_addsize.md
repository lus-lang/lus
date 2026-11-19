---
name: luaL_addsize
header: lauxlib.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define luaL_addsize(B,s) ((B)->n += (s))"
---

Adds to the buffer a string of length `s` previously copied to the buffer area.
