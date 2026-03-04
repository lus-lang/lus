---
name: lus_checkfsperm
header: lpledge.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "int lus_checkfsperm (lua_State *L, const char *perm, const char *path)"
params:
  - name: L
    type: "lua_State*"
  - name: perm
    type: "const char*"
  - name: path
    type: "const char*"
---

Convenience function for filesystem permission checks. Raises an error if denied.
