---
name: table.remove
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
returns: any
---

Removes the element at position `pos` from the list `list`, shifts the elements after it down by one, and returns the removed element.

`list` is the table to modify. `pos` is the position to remove and defaults to `#list`, so the call without it removes the last element. `pos` may be any integer from 1 to `#list + 1`. When `#list` is 0, `pos` may also be 0.

The result is the value that was at `pos`, which is `nil` for an empty list or for `pos` equal to `#list + 1`. The elements after `pos` move down, and the last position becomes `nil`.

A `pos` outside the allowed range raises `bad argument #2 to 'remove' (position out of bounds)`. A `list` that is not a table raises a type error.

```lus
local list = {"a", "b", "c"}
print(table.remove(list), table.concat(list, ","))     --> c  a,b
print(table.remove(list, 1), table.concat(list, ","))  --> a  b
print(table.remove({}))                                --> nil
print(catch table.remove({1}, 3))  --> false  ...: bad argument #2 to 'remove' (position out of bounds)
```

The elements are read and written through `__index` and `__newindex`, and the length comes from `__len`. Removing from the front of a long list moves every element after it, so a queue that removes from the front keeps a head index. [`table.insert`](/manual/api#table.insert) is the inverse.
