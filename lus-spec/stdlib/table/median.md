---
name: table.median
module: table
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: array
    type: table
returns: number
---

Computes the median of numeric values in `array`. Returns the middle value for odd-length arrays, or the average of the two middle values for even-length arrays. Non-numeric values are skipped. Does not modify the original table. Returns NaN if no numeric values exist.
