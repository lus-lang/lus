---
name: "lus_len"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_len(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
    name: status
---

Pushes the length of the value at `idx`, as the `#` operator computes it, and returns `LUS_OK`. A `__len` metamethod runs, and the length of a string counts its characters. On failure the call returns the status and pushes the error value in place of the length.

`lus_rawlen` returns a length directly without metamethods.
