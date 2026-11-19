---
name: lus_issealed
header: lpledge.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "int lus_issealed (lua_State *L)"
params:
  - name: L
    type: "lua_State*"
---

Returns `1` if the permission state is sealed, `0` otherwise.
