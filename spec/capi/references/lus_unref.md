---
name: "lus_unref"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_unref(lus_State *L, int ref)"
params:
  - name: L
    type: "lus_State*"
  - name: ref
    type: "int"
---

Releases a reference, so its value can be collected and its number can be returned again by a later `lus_ref`. Releasing `LUS_NOREF` or a reference that is already released does nothing.
