---
name: lua_tostring
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_tostring(L,i) lua_tolstring(L,(i),NULL)"
---

Equivalent to `lua_tolstring` with `len` equal to NULL.
