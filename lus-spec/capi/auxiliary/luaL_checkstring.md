---
name: luaL_checkstring
header: lauxlib.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define luaL_checkstring(L,n) (luaL_checklstring(L,(n),NULL))"
---

Checks whether the function argument `n` is a string and returns it.
