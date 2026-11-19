---
name: "lus_rawget"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_rawget(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
    name: type
---

Pops a key and pushes the value of `t[key]` without calling metamethods, where `t` is the table at `idx`, and returns the [type code](#LUS_T*) of the pushed value. A value at `idx` that is not a table gives nil. The call never fails.
