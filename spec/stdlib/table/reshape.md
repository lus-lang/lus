---
name: table.reshape
module: table
kind: function
since: 1.6.0
stability: stable
origin: lus
fastcall: true
params:
  - name: array
    type: table
  - name: rows
    type: integer
  - name: cols
    type: integer
returns: table
---

Returns a new matrix with `rows` rows and `cols` columns, filled with the elements of the list `array` in row-major order.

`array` is the list to read, from index 1 to `#array`. `rows` and `cols` are positive integers, and their product must equal `#array`.

The result is a new table of `rows` tables, each holding `cols` elements. Element `(r - 1) * cols + c` of `array` becomes `result[r][c]`. `array` is not modified.

A length that does not match raises `array length 3 does not match 2 x 2` with the actual numbers. A `rows` or `cols` of zero or less raises `bad argument #2 to 'table.reshape' (rows must be positive)` or `bad argument #3 to 'table.reshape' (cols must be positive)`.

```lus
local m = table.reshape({ 1, 2, 3, 4, 5, 6 }, 2, 3)
print(#m, table.concat(m[1], ","), table.concat(m[2], ","))  --> 2  1,2,3  4,5,6
print(catch table.reshape({ 1, 2, 3 }, 2, 2))  --> false  ...: array length 3 does not match 2 x 2
```

An empty list has no valid shape, since both dimensions must be positive. [`table.transpose`](/manual/api#table.transpose) swaps the rows and columns of the result.
