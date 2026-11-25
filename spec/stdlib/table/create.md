---
name: table.create
module: table
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: narray
    type: integer
  - name: nhash
    type: integer
    optional: true
returns: table
---

Returns a new empty table with storage reserved for `narray` array elements and `nhash` other keys.

`narray` is the number of elements of the array part to reserve. `nhash` is the number of keys of the hash part to reserve and defaults to 0. Both are integers from 0 to 2147483647.

The result is a new empty table, so `#t` is 0 and `next(t)` is `nil`. The reservation saves the reallocations that a table makes as it grows to a size known in advance.

A count outside the range raises `bad argument #1 to 'create' (out of range)`, naming the argument. A missing `narray` raises a type error.

```lus
local squares = table.create(100)
print(#squares)  --> 0

for i = 1, 100 do
    squares[i] = i * i
end

print(#squares, squares[100])  --> 100  10000
```

[`table.compact`](/manual/api#table.compact) releases storage that a table no longer uses.
