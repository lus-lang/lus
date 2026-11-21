---
name: table.pack
module: table
kind: function
since: 0.1.0
stability: stable
origin: lua
vararg: true
returns: table
---

Returns a new table that holds all its arguments as the elements 1 through `n`, with the field `n` set to the number of arguments.

The arguments are any values, including `nil`.

The result is a new table. The field `n` counts every argument, including trailing `nil` values, so it gives the true count even when the arguments contain `nil`.

The function raises no errors of its own.

```lus
local p = table.pack(1, nil, 3)
print(p.n, p[1], p[2], p[3])   --> 3  1  nil  3
print(table.pack().n)          --> 0
```

[`table.unpack`](/manual/api#table.unpack) is the inverse: `table.unpack(p, 1, p.n)` returns the original arguments, `nil` values included.
