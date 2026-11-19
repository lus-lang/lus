---
name: lua_tonumber
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_tonumber(L,i) lua_tonumberx(L,(i),NULL)"
---

Converts the value at the given index to a `lua_Number`.
