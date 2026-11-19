---
name: "lus_gettable"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_gettable(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
    name: status
---

Pops a key and pushes `t[key]`, where `t` is the value at `idx`, and returns `LUS_OK`. The lookup honors `__index`. On failure the call returns the status and the error value replaces the key, so the number of values stays the same in every case.
