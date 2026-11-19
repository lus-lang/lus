---
name: "lus_absindex"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_absindex(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
---

Converts `idx` into the positive index of the same slot. A positive index is returned unchanged. Converting first keeps an index valid while the function pushes more values, which is useful in helpers that receive an index from their caller.
