---
name: lua_call
header: lua.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define lua_call(L,n,r) lua_callk(L,(n),(r),0,NULL)"
---

Calls a function (macro for `lua_callk` with no continuation).
