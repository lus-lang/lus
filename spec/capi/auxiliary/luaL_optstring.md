---
name: luaL_optstring
header: lauxlib.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define luaL_optstring(L,n,d) (luaL_optlstring(L,(n),(d),NULL))"
---

Returns string argument `n` when supplied, or default value `d` when the argument is absent or nil.
