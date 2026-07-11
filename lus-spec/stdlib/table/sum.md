---
name: table.sum
module: table
kind: function
since: 1.6.0
stability: stable
origin: lus
fastcall: true
params:
  - name: array
    type: table
returns: number
---

Computes the sum of numeric values in `array`. Strings naming a number count as numeric values and are coerced. Other non-numeric values are skipped. Returns `0` for an empty table.
