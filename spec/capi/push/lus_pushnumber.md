---
name: "lus_pushnumber"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_pushnumber(lus_State *L, lus_Number n)"
params:
  - name: L
    type: "lus_State*"
  - name: n
    type: "lus_Number"
---

Pushes `n` as a float, also when its value is integral. `lus_pushinteger` pushes an integer.
