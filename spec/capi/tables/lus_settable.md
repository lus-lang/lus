---
name: "lus_settable"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_settable(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
    name: status
---

Does `t[key] = value`, where `t` is the value at `idx`, `value` is the top value, and `key` is the value below it, and returns `LUS_OK`. The assignment honors `__newindex`.

On success both values are popped. On failure the call returns the status and the error value replaces the two values.
