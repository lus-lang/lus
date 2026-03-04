---
name: lus_revokepledge
header: lpledge.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "int lus_revokepledge (lua_State *L, const char *name)"
params:
  - name: L
    type: "lua_State*"
  - name: name
    type: "const char*"
---

Revokes a previously granted permission. Returns `1` on success, `0` if sealed or not found.
