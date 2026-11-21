---
name: table.insert
module: table
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: list
    type: table
  - name: pos
    type: integer
    optional: true
  - name: value
    type: any
    optional: true
---

Inserts `value` into the list `list` at position `pos`, shifting the elements at `pos` and after it up by one, or appends `value` when `pos` is omitted.

The call takes two or three arguments. `table.insert(list, value)` stores `value` at `#list + 1`. `table.insert(list, pos, value)` moves the elements `list[pos]` through `list[#list]` up by one position and stores `value` at `pos`, which is an integer from 1 to `#list + 1`.

The function returns no values. `list` is modified in place.

A `pos` outside the range from 1 to `#list + 1` raises `bad argument #2 to 'insert' (position out of bounds)`. One argument, or more than three, raises `wrong number of arguments to 'insert'`. A `list` that is not a table, and has no `__index`, `__newindex`, and `__len` metamethods, raises a type error.

```lus
local list = {"b", "c"}
table.insert(list, "d")
table.insert(list, 1, "a")
print(table.concat(list, ","))   --> a,b,c,d
print(catch table.insert(list, 9, "z"))  --> false  ...: bad argument #2 to 'insert' (position out of bounds)
```

The elements are read and written through `__index` and `__newindex`, and the length comes from `__len`. Appending `nil` stores nothing, so the list keeps its length. [`table.remove`](/manual/api#table.remove) is the inverse, and [`table.move`](/manual/api#table.move) shifts a whole range at once.
