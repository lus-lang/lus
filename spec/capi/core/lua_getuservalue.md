---
name: lua_getuservalue
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_getuservalue(L,idx) lua_getiuservalue(L,idx,1)"
---

Compatibility macro. Gets the first user value of a userdata.
