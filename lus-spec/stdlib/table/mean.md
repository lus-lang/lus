---
name: table.mean
module: table
kind: function
since: 1.6.0
stability: unstable
origin: lus
fastcall: true
params:
  - name: array
    type: table
returns: number
---

Computes the arithmetic mean of numeric values in `array`. Non-numeric values are skipped. Returns NaN if no numeric values exist.
