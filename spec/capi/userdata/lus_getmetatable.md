---
name: "lus_getmetatable"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_getmetatable(lus_State *L, const char *tname)"
params:
  - name: L
    type: "lus_State*"
  - name: tname
    type: "const char*"
---

Pushes the metatable registered under the type name `tname` by `lus_newmetatable`, or nil when there is none. The call never fails.
