---
name: table.unpack
module: table
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: list
    type: table
  - name: i
    type: integer
    optional: true
  - name: j
    type: integer
    optional: true
returns: any
---

Returns the elements `list[i]` through `list[j]` as separate values.

`list` is the table to read. `i` defaults to 1, and `j` defaults to the length `#list`.

The results are `j - i + 1` values in order, with `nil` for each missing element in the range. When `i` is greater than `j`, there are no results.

A range of more values than the stack can hold raises `too many results to unpack`. A `list` that is not a table raises a type error.

```lus
print(table.unpack({1, 2, 3}))         --> 1  2  3
print(table.unpack({1, 2, 3}, 2))      --> 2  3
print(table.unpack({1, 2, 3}, 2, 5))   --> 2  3  nil  nil
print(select("#", table.unpack({1, 2}, 3)))  --> 0
```

The elements are read through `__index` and the length through `__len`. [`table.pack`](/manual/api#table.pack) is the inverse, and its field `n` gives the `j` that restores trailing `nil` values.
