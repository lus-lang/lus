---
name: table.sum
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

Returns the sum of the numeric values in the list `array`, as a float.

`array` is the list to read, from index 1 to `#array`. Numbers of every subtype count, converted to the nearest float. Strings naming a number count as numeric values and are coerced. Other values are skipped.

The result is always a float, even when every value is an integer. An empty list, or one with no numeric values, returns 0.0.

An `array` that is not a table raises `bad argument #1 to 'table.sum' (table expected, got nil)` with its type.

```lus
print(table.sum({1, 2, 3}))           --> 6.0
print(table.sum({0.1, 0.2}))          --> 0.30000000000000004
print(table.sum({"1", "a", 2, true})) --> 3.0
print(table.sum({}))                  --> 0.0
```

The sum is computed in floating point in a fixed order. The value at index `i` is added into accumulator `(i - 1) % 8`, starting from eight zeros, and the accumulators are then combined pairwise: accumulator `j` with `j + 4` for `j` from 0 to 3, then the first of those four sums with the third and the second with the fourth, and finally those two. The result is therefore the same on every platform and for every way the table is stored. Bigints and decimals lose the digits that a float cannot hold, so an exact total of such values comes from [`table.reduce`](/manual/api#table.reduce) with the `+` operator. [`table.mean`](/manual/api#table.mean) divides the sum by the count.
