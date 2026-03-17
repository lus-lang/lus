---
name: table.transpose
module: table
kind: function
since: 1.6.0
stability: unstable
origin: lus
fastcall: true
params:
  - name: matrix
    type: table
returns: table
---

Transposes a 2D table (matrix) so that `result[i][j] == matrix[j][i]`. All rows must have the same length. Raises an error for non-rectangular matrices.
