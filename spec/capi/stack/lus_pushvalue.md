---
name: "lus_pushvalue"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_pushvalue(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
---

Pushes a copy of the value at `idx`. An index that names no value pushes nil. Tables, functions, and other objects are copied by reference, so both slots then hold the same object.
