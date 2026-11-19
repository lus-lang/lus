---
name: "lus_replace"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_replace(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
---

Pops the top value and stores it at `idx`, overwriting the value there. The values between them keep their positions.
