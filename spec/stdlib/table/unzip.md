---
name: table.unzip
module: table
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: array_of_tuples
    type: table
returns:
  - type: table
    name: "..."
---

Splits a list of tuples into separate lists, one for each position in the tuples, and returns them as multiple values.

`array_of_tuples` is a list of tables. The number of results is the length of the first tuple.

The results are one new list for each position. List `k` holds element `k` of every tuple, in order. A tuple shorter than the first leaves a `nil` at its index, and elements beyond the length of the first tuple are ignored. An empty list, or a first tuple of length 0, returns no values.

A first element that is not a table raises `bad argument #-1 to 'unzip' (table expected, got number)` with its type. An `array_of_tuples` that is not a table raises a type error.

```lus
local ids, names = table.unzip({{1, "a"}, {2, "b"}, {3, "c"}})
print(table.concat(ids, ","), table.concat(names, ","))   --> 1,2,3  a,b,c
print(select("#", table.unzip({})))                        --> 0
```

`table.unzip` is the inverse of [`table.zip`](/manual/api#table.zip). For tuples of equal length, [`table.transpose`](/manual/api#table.transpose) returns the same lists as one table.
