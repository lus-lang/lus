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

Returns the standard deviation of the numeric values in the list `array`, as a float.

`array` is the list to read, from index 1 to `#array`. Numbers of every subtype count, converted to the nearest float. Strings naming a number count as numeric values and are coerced. Other values are skipped. When `sample` is truthy, the sum of squared deviations is divided by `n - 1`, which gives the sample standard deviation. Otherwise it is divided by `n`, which gives the population standard deviation. `sample` defaults to false.

The result is a non-negative float. A list with no numeric values returns NaN, and so does a sample of fewer than two values. A population of one value returns 0.0.

An `array` that is not a table raises `bad argument #1 to 'table.stdev' (table expected, got nil)` with its type.

```lus
local data = {2, 4, 4, 4, 5, 5, 7, 9}
print(table.stdev(data))          --> 2.0
print(table.stdev(data, true))    --> 2.138089935299395
print(table.stdev({5}), table.stdev({5}, true))  --> 0.0  nan
```

The mean, and then the sum of squared deviations from it, are each computed in floating point in a fixed order. The term for index `i` is added into accumulator `(i - 1) % 8`, starting from eight zeros, and the accumulators are then combined pairwise: accumulator `j` with `j + 4` for `j` from 0 to 3, then the first of those four sums with the third and the second with the fourth, and finally those two. The result is therefore the same on every platform and for every way the table is stored. [`table.mean`](/manual/api#table.mean) returns the average.
