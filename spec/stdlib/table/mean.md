---
name: table.mean
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

Computes the arithmetic mean of numeric values in `array`. Strings naming a number count as numeric values and are coerced. Other non-numeric values are skipped. Returns NaN if no numeric values exist.

The sum it divides is computed in floating point in a fixed order. The value at index `i` is added into accumulator `(i - 1) % 8`, starting from eight zeros, and the accumulators are then combined pairwise: accumulator `j` with `j + 4` for `j` from 0 to 3, then the first of those four sums with the third and the second with the fourth, and finally those two. The result is therefore the same on every platform and for every way the table is stored.
