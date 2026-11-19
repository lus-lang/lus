---
name: "lus_pop"
header: lus.h
kind: macro
since: "2.0.0"
stability: stable
origin: lus
signature: "#define lus_pop(L, n) lus_settop(L, -(n)-1)"
---

Removes the top `n` values. It expands to a call of `lus_settop`, so popping more values than the frame holds empties the frame.
