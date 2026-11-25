---
name: table.map
module: table
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: array
    type: table
  - name: func
    type: function
returns: table
---

Returns a new list in which element `i` is `func(array[i], i)`.

`array` is the list to read, from index 1 to `#array`. `func` is a function called once for each element, in order, with the element and its index as arguments. Only the first value it returns is kept.

The result is a new table with one entry for each index. A `nil` result leaves a hole at its index. `array` is not modified.

An `array` that is not a table raises a type error, and so does a `func` that is not a function. An error raised by `func` propagates.

```lus
local doubled = table.map({ 1, 2, 3 }, function(x)
    return x * 2
end)

print(table.concat(doubled, ","))  --> 2,4,6

local tagged = table.map({ "a", "b" }, function(x, i)
    return `$i:$x`
end)

print(table.concat(tagged, " "))  --> 1:a 2:b
```

[`table.filter`](/manual/api#table.filter) keeps some elements, and [`table.reduce`](/manual/api#table.reduce) folds a list into one value.
