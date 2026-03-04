---
name: lus_pledge
header: lpledge.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "int lus_pledge (lua_State *L, const char *name, const char *value)"
params:
  - name: L
    type: "lua_State*"
  - name: name
    type: "const char*"
  - name: value
    type: "const char*"
---

Grants a permission to the Lua state. Triggers the granter callback for validation. Returns `1` on success, `0` if denied or sealed.
