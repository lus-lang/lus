---
name: lus_rejectpledge
header: lpledge.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "int lus_rejectpledge (lua_State *L, const char *name)"
params:
  - name: L
    type: "lua_State*"
  - name: name
    type: "const char*"
---

Permanently rejects a permission by name. Returns `1` on success, `0` if sealed.
