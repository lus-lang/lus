---
name: table.clone
module: table
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: t
    type: T
  - name: deep
    type: boolean
    optional: true
generic: T
returns: T
---

Returns a new table with the keys, values, and metatable of `t`, and copies the nested tables too when `deep` is true.

`t` is the table to copy. `deep` defaults to false. A shallow copy shares every nested table with `t`. A deep copy clones every table it reaches through a key or a value, including tables used as keys.

The result is a new table. It has the same metatable as `t`, and the metatable itself is shared in both modes. The copy reads `t` raw, without calling `__index` or `__pairs`, and the new table is writable even when `t` is read-only. A deep copy clones each distinct table once, so a table reached twice in `t` becomes one table reached twice in the copy, and a cycle in `t` becomes the same cycle in the copy.

A `t` that is not a table raises `bad argument #1 to 'clone' (table expected, got string)` with its type. A deep copy of tables nested more than 200 levels deep raises `table.clone: nesting too deep (max 200)`.

```lus
local t = { 1, { 2, 3 }, name = "x" }
local shallow = table.clone(t)
local deep = table.clone(t, true)
print(shallow[2] == t[2], deep[2] == t[2])  --> true  false
print(deep[2][2], deep.name)  --> 3  x
local loop = {}
loop.self = loop
local copy = table.clone(loop, true)
print(copy.self == copy, copy ~= loop)  --> true  true
```

Values other than tables, such as functions, userdata, and coroutines, are shared by both modes. [`table.move`](/manual/api#table.move) copies a range of a list into another table.
