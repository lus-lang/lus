---
name: lus_haspledge
header: lpledge.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "int lus_haspledge (lua_State *L, const char *name, const char *value)"
params:
  - name: L
    type: "lua_State*"
  - name: name
    type: "const char*"
  - name: value
    type: "const char*"
---

Checks if a permission has been granted. Returns `1` if access is allowed, `0` if denied.
