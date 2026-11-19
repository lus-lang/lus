---
name: "lus_pushinteger"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_pushinteger(lus_State *L, lus_Integer n)"
params:
  - name: L
    type: "lus_State*"
  - name: n
    type: "lus_Integer"
---

Pushes `n` as an integer.
