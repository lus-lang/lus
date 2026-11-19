---
name: "lus_remove"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_remove(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
---

Removes the value at `idx` and shifts the values above it down by one slot. An index that names no value leaves the stack unchanged.
