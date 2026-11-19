---
name: "lus_rawset"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_rawset(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
    name: status
---

Does `t[key] = value` without calling metamethods, where `t` is the table at `idx`, `value` is the top value, and `key` is the value below it, and returns `LUS_OK`. Both values are popped.

The call fails when the value at `idx` is not a table or the key is nil or NaN. It then returns `LUS_ERRRUN` and the error value replaces the two values.
