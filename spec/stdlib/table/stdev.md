---
name: table.stdev
module: table
kind: function
since: 1.6.0
stability: stable
origin: lus
fastcall: true
params:
  - name: array
    type: table
  - name: sample
    type: boolean
    optional: true
returns: number
---

Computes the standard deviation of numeric values in `array`. When `sample` is `true`, divides by n-1 (sample standard deviation). Otherwise divides by n (population standard deviation). Strings naming a number count as numeric values and are coerced. Other non-numeric values are skipped. Returns NaN if no numeric values exist.
