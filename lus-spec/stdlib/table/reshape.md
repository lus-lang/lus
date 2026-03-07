---
name: table.reshape
module: table
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: array
    type: table
  - name: rows
    type: integer
  - name: cols
    type: integer
returns: table
---

Reshapes a 1D array into a 2D matrix with the specified dimensions, filled in row-major order. The array length must equal `rows * cols`.
