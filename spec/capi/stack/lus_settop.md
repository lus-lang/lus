---
name: "lus_settop"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_settop(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
---

Sets the top of the frame. A positive or zero `idx` becomes the new number of values. Slots added above the old top hold nil, and `lus_settop(L, 0)` empties the frame.

A negative `idx` counts from the top, so `lus_settop(L, -1)` leaves the stack as it is and `lus_settop(L, -3)` removes two values. A negative index below the bottom of the frame empties it.
