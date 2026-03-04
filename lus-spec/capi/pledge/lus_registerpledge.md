---
name: lus_registerpledge
header: lpledge.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "void lus_registerpledge (lua_State *L, const char *name, lus_PledgeGranter granter)"
params:
  - name: L
    type: "lua_State*"
  - name: name
    type: "const char*"
  - name: granter
    type: lus_PledgeGranter
---

Registers a granter callback for a permission namespace.
