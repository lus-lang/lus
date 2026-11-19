---
name: "lus_getmetatableof"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_getmetatableof(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
---

Pushes the metatable of the value at `idx` and returns 1, or pushes nothing and returns 0 when the value has none. Strings share one metatable, which this call also returns.
