---
name: table.move
module: table
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: a1
    type: table
  - name: f
    type: integer
  - name: e
    type: integer
  - name: t
    type: integer
  - name: a2
    type: table
    optional: true
returns: table
---

Copies the elements `a1[f]` through `a1[e]` into the table `a2` starting at position `t`, and returns `a2`.

`a1` is the source table. `f` and `e` are the first and the last source positions, and `t` is the first destination position. `a2` is the destination table and defaults to `a1`, which moves elements within one table.

The result is `a2`. The copy handles overlapping ranges in one table correctly, so shifting a range up or down by a few positions never reads an element it already overwrote. When `e` is less than `f`, nothing is copied.

A missing position raises a type error such as `bad argument #4 to 'move' (number expected, got no value)`. A range of more elements than an integer can count raises `too many elements to move`, and a destination that would pass `math.maxinteger` raises `destination wrap around`.

```lus
local a = { 1, 2, 3, 4, 5 }
table.move(a, 1, 3, 3)
print(table.concat(a, ","))  --> 1,2,1,2,3
local copy = table.move({ 1, 2, 3 }, 1, 3, 1, {})
print(table.concat(copy, ","))  --> 1,2,3
```

The elements are read through `__index` and written through `__newindex`. The source elements outside the destination range stay where they are, so moving a range down leaves its old tail in place. [`table.clone`](/manual/api#table.clone) copies a whole table.
