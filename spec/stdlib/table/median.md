---
name: table.median
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

Returns the median of the numeric values in the list `array`, as a float.

`array` is the list to read, from index 1 to `#array`. Numbers of every subtype count, converted to the nearest float. Strings naming a number count as numeric values and are coerced. Other values are skipped.

The result is a float. With an odd count of numeric values it is the middle value in sorted order, and with an even count it is the average of the two middle values. A list with no numeric values returns NaN. `array` is not modified, since the values are sorted in a copy.

An `array` that is not a table raises `bad argument #1 to 'table.median' (table expected, got nil)` with its type.

```lus
print(table.median({3, 1, 2}))        --> 2.0
print(table.median({4, 1, 3, 2}))     --> 2.5
print(table.median({"5", 1, "x"}))    --> 3.0
print(table.median({}))               --> nan
```

A NaN among the values makes the result unspecified. [`table.mean`](/manual/api#table.mean) returns the average, and [`table.stdev`](/manual/api#table.stdev) the spread.
