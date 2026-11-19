---
name: lua_setuservalue
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_setuservalue(L,idx) lua_setiuservalue(L,idx,1)"
---

Compatibility macro. Sets the first user value of a userdata.
