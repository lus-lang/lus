---
name: lua_tointeger
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_tointeger(L,i) lua_tointegerx(L,(i),NULL)"
---

Converts the value at the given index to a `lua_Integer`.
