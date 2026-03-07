---
name: table.reduce
module: table
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: array
    type: table
  - name: func
    type: function
  - name: initial
    type: any
    optional: true
returns: any
---

Reduces `array` to a single value by iteratively applying `func(accumulator, element, index)`. If `initial` is not provided, the first element is used and iteration starts from the second. Raises an error if `initial` is not provided and the array is empty.
