---
name: table.groupby
module: table
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: array
    type: table
  - name: keyfunc
    type: function
returns: table
---

Returns a table that maps each key returned by `keyfunc(element)` to a list of the elements of `array` that produced that key.

`array` is the list to read, from index 1 to `#array`. `keyfunc` is a function called once for each element, in order, with the element as its only argument.

The result is a new table. Each list in it holds its elements in their original order. The keys are normalized as table keys, so the float `1.0` and the integer `1` name the same group.

A `keyfunc` that returns `nil` raises `table index is nil`, and one that returns NaN raises `table index is NaN`. An `array` that is not a table, or a `keyfunc` that is not a function, raises a type error.

```lus
local groups = table.groupby({ 1, 2, 3, 4, 5 }, function(x)
    return x % 2 == 0 and "even" or "odd"
end)

print(table.concat(groups.odd, ","), table.concat(groups.even, ","))  --> 1,3,5  2,4
```

The order in which `pairs` visits the groups is unspecified. [`table.filter`](/manual/api#table.filter) keeps the elements of one group, and [`table.sortby`](/manual/api#table.sortby) orders a list by a key.
