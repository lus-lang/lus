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

Returns the arithmetic mean of the numeric values in the list `array`, as a float.

`array` is the list to read, from index 1 to `#array`. Numbers of every subtype count, converted to the nearest float. Strings naming a number count as numeric values and are coerced. Other values, such as booleans and tables, are skipped and do not count toward the divisor.

The result is a float. A list with no numeric values returns NaN.

An `array` that is not a table raises `bad argument #1 to 'table.mean' (table expected, got nil)` with its type.

```lus
print(table.mean({ 1, 2, 3, 4 }))  --> 2.5
print(table.mean({ 1, "3", "x", true }))  --> 2.0
print(table.mean({}))  --> nan
```

The sum it divides is computed in floating point in a fixed order. The value at index `i` is added into accumulator `(i - 1) % 8`, starting from eight zeros, and the accumulators are then combined pairwise: accumulator `j` with `j + 4` for `j` from 0 to 3, then the first of those four sums with the third and the second with the fourth, and finally those two. The result is therefore the same on every platform and for every way the table is stored. Bigints and decimals lose the digits that a float cannot hold. [`table.sum`](/manual/api#table.sum), [`table.median`](/manual/api#table.median), and [`table.stdev`](/manual/api#table.stdev) compute the other statistics.
