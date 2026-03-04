---
name: luaL_optstring
header: lauxlib.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define luaL_optstring(L,n,d) (luaL_optlstring(L,(n),(d),NULL))"
---

If the function argument `n` is a string, returns it; otherwise returns `d`.
