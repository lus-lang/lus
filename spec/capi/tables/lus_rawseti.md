---
name: "lus_rawseti"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_rawseti(lus_State *L, int idx, lus_Integer n)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
  - name: n
    type: "lus_Integer"
returns:
  - type: "int"
    name: status
---

Pops a value and stores it at `t[n]` without calling metamethods, where `t` is the table at `idx`, and returns `LUS_OK`. When the value at `idx` is not a table, it returns `LUS_ERRRUN` and the error value replaces the value.
