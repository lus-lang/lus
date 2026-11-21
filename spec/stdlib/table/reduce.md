---
name: table.reduce
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
  - name: initial
    type: any
    optional: true
returns: any
---

Reduces the list `array` to a single value by calling `func(accumulator, element, index)` for each element in order, and returns the final accumulator.

`array` is the list to read, from index 1 to `#array`. `func` receives the accumulator, the element, and its index, and its first result becomes the next accumulator. `initial` is the first accumulator. When `initial` is `nil` or omitted, the first element is the first accumulator and the calls start from the second element.

The result is the value that the last call returned. With an `initial`, an empty list returns `initial` without calling `func`. Without one, a list of one element returns that element.

An empty list with no `initial` raises `'reduce' on empty table with no initial value`. An `array` that is not a table, or a `func` that is not a function, raises a type error. An error raised by `func` propagates.

```lus
local function add(acc, x) return acc + x end
print(table.reduce({1, 2, 3, 4}, add))        --> 10
print(table.reduce({1, 2, 3, 4}, add, 100))   --> 110
print(table.reduce({}, add, 0))               --> 0
print(table.reduce({"a", "b"}, function(acc, x, i) return acc .. x .. i end, ""))  --> a1b2
```

`nil` cannot serve as the initial accumulator, since it reads as an omitted `initial`. [`table.sum`](/manual/api#table.sum) adds numbers directly, and [`table.map`](/manual/api#table.map) transforms each element.
