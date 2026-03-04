---
name: lua_isnoneornil
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_isnoneornil(L,n) (lua_type(L,(n)) <= 0)"
---

Returns 1 if the given index is not valid or the value is nil.
