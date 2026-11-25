---
name: table.filter
module: table
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: array
    type: table
  - name: predicate
    type: function
returns: table
---

Returns a new list of the elements of `array` for which `predicate(element)` returns a truthy value, in their original order.

`array` is the list to read, from index 1 to `#array`. `predicate` is a function called once for each element, in order, with the element as its only argument.

The result is a new dense list, so its elements are numbered from 1 without holes. `array` is not modified. An empty list returns an empty list.

An `array` that is not a table raises a type error, and so does a `predicate` that is not a function. An error raised by `predicate` propagates.

```lus
local odd = table.filter({ 1, 2, 3, 4, 5 }, function(x)
    return x % 2 == 1
end)

print(#odd, table.concat(odd, ","))  --> 3  1,3,5

local words = table.filter({ "a", "", "b" }, function(s)
    return #s > 0
end)

print(table.concat(words, " "))  --> a b
```

[`table.map`](/manual/api#table.map) transforms each element, and [`table.reduce`](/manual/api#table.reduce) folds a list into one value.
