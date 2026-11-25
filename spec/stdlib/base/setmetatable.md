---
name: setmetatable
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: t
    type: T
  - name: metatable
    type: table|nil
generic: T
returns: T
---

`setmetatable(t, metatable)` sets the metatable of the table `t` to `metatable` and returns `t`.

The parameter `t` must be a table, and any other value raises `bad argument #1 to 'setmetatable' (table expected, got TYPE)`. The parameter `metatable` is a table, or `nil` to remove the metatable. A missing `metatable` counts as `nil`, and any other value raises `bad argument #2 to 'setmetatable' (nil or table expected, got TYPE)`.

A lookup follows a chain of `__index` tables, or of `__newindex` tables for an assignment, through at most 2,000 tables, and a longer chain raises `'__index' chain too long, possible loop` or `'__newindex' chain too long, possible loop`, which also catches a chain that leads back to itself. A call follows a chain of `__call` tables through at most 15 tables, and a longer chain raises `'__call' chain too long`. If the current metatable of `t` has a `__metatable` field, the metatable is protected, and `setmetatable` raises `cannot change a protected metatable`. A read-only table, such as `flags` or a table that `--readonly-env` froze, keeps its metatable, and `setmetatable` on it raises `attempt to modify a readonly table`. A metatable with a `__gc` field marks `t` for finalization when it is set.

```lus
local Point = {}
Point.__index = Point

function Point:norm()
    return math.sqrt(self.x ^ 2 + self.y ^ 2)
end

local p = setmetatable({ x = 3, y = 4 }, Point)
print(p:norm(), getmetatable(p) == Point)  --> 5.0  true
```

[`getmetatable`](/manual/api#getmetatable) reads a metatable. The metatables of other types, such as the shared metatable of strings, are set through [`debug.setmetatable`](/manual/api#debug.setmetatable). [Metatables and metamethods](/manual/guide#metatables-and-objects) in the guide lists the metamethods.
