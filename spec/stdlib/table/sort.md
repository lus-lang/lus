---
name: table.sort
module: table
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: list
    type: table
  - name: comp
    type: function
    optional: true
---

Sorts the elements `list[1]` through `list[#list]` in place, in ascending order or in the order that `comp` defines.

`list` is the table to sort. `comp` is an optional function that takes two elements and returns `true` when the first must come before the second. Without `comp`, the elements are compared with the `<` operator, so numbers of every subtype sort by their mathematical value and strings sort by their code points.

The function returns no values. The sort is not stable, so elements that compare equal may change their relative order.

Elements that `<` cannot compare raise the comparison error, such as `attempt to compare string with number`. A `comp` that is not a function raises `bad argument #2 to 'sort' (function expected, got number)` with its type. A `comp` that is not a consistent order may raise `invalid order function for sorting`. A list of 2147483647 elements or more raises `array too big`.

```lus
local list = { 5, 2, 8, 1 }
table.sort(list)
print(table.concat(list, ","))  --> 1,2,5,8

table.sort(list, function(a, b)
    return a > b
end)

print(table.concat(list, ","))  --> 8,5,2,1
local mixed = { 3, 1.5, 2n, 0.5d }
table.sort(mixed)
print(mixed[1], mixed[2], mixed[3], mixed[4])  --> 0.5  1.5  2  3
```

Uppercase letters sort before lowercase ones, since the comparison follows code points. [`table.sortby`](/manual/api#table.sortby) sorts stably by a key computed once for each element.
