---
name: luaL_argcheck
header: lauxlib.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define luaL_argcheck(L,cond,arg,extramsg)"
---

Checks whether `cond` is true. If not, raises an argument error.
