---
name: "lus_rawlen"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "size_t lus_rawlen(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "size_t"
---

Returns the length of the value at `idx` without calling metamethods. It is the length in bytes for a string, the length of a vector, and a border of the sequence for a table. Every other type gives 0.

The length in bytes of a string can differ from the result of the `#` operator, which counts characters. `lus_len` computes that one.
