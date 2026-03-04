---
name: lua_newuserdata
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_newuserdata(L,s) lua_newuserdatauv(L,s,1)"
---

Compatibility macro. Creates a new userdata with one user value.
