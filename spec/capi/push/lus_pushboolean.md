---
name: "lus_pushboolean"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_pushboolean(lus_State *L, int b)"
params:
  - name: L
    type: "lus_State*"
  - name: b
    type: "int"
---

Pushes true when `b` is not zero and false when it is zero.
