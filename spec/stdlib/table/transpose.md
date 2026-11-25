---
name: table.transpose
module: table
kind: function
since: 1.6.0
stability: stable
origin: lus
fastcall: true
params:
  - name: matrix
    type: table
returns: table
---

Returns a new matrix whose rows are the columns of `matrix`, so that `result[i][j]` equals `matrix[j][i]`.

`matrix` is a list of rows, and each row is a list. Every row must have the same length as the first.

The result is a new table of `#matrix[1]` rows, each with `#matrix` elements. An empty `matrix` returns an empty table. `matrix` is not modified.

Rows of different lengths raise `non-rectangular matrix in 'transpose'`. A row that is not a table raises `bad argument #-1 to 'transpose' (table expected, got number)` with its type.

```lus
local t = table.transpose({ { 1, 2, 3 }, { 4, 5, 6 } })
print(#t, table.concat(t[1], ","), table.concat(t[3], ","))  --> 3  1,4  3,6
print(catch table.transpose({ { 1, 2 }, { 3 } }))  --> false  ...: non-rectangular matrix in 'transpose'
```

Transposing twice returns a matrix equal to the original. [`table.reshape`](/manual/api#table.reshape) builds a matrix from a flat list, and [`table.zip`](/manual/api#table.zip) combines separate lists into rows.
