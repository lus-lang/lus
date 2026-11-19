---
name: "lus_newtable"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_newtable(lus_State *L, int narr, int nrec)"
params:
  - name: L
    type: "lus_State*"
  - name: narr
    type: "int"
  - name: nrec
    type: "int"
returns:
  - type: "int"
    name: status
---

Pushes a new empty table and returns `LUS_OK`. The table has room for `narr` items in its sequence and `nrec` other fields before it grows. Both sizes are hints, and a negative size counts as 0. On failure it returns `LUS_ERRMEM` and pushes the error value in place of the table.
