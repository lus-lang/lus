---
name: "lus_tonumber"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "lus_Number lus_tonumber(lus_State *L, int idx, int *isnum)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
  - name: isnum
    type: "int*"
returns:
  - type: "lus_Number"
---

Returns the value at `idx` as a float. Integers, floats, and strings holding a numeral convert. A bigint or a decimal converts to the nearest float.

When `isnum` is not `NULL`, it receives 1 when the conversion succeeded and 0 otherwise. A failed conversion returns 0.
