---
name: "lus_checkstack"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_checkstack(lus_State *L, int n)"
params:
  - name: L
    type: "lus_State*"
  - name: n
    type: "int"
returns:
  - type: "int"
---

Makes room for `n` more values and returns 1, or returns 0 when the stack cannot grow that far. The stack grows on its own with every push up to one million slots, so `lus_checkstack` serves as an early check before a host pushes a large number of values.
