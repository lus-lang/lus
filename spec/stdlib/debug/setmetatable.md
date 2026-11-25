---
name: debug.setmetatable
module: debug
kind: function
since: 0.1.0
pledges: ["debug"]
stability: stable
origin: lua
params:
  - name: value
    type: any
  - name: t
    type: table|nil
returns: any
---

Sets the metatable of a value of any type and returns the value, ignoring any `__metatable` protection.

- `value` is the value whose metatable changes.
- `t` is the new metatable, a table, or `nil` to remove the metatable.

The function returns `value`. A table and a full userdata each have a metatable of their own. Every other type shares one metatable among all its values, so setting the metatable of one number sets it for every number, integers and floats alike. A `t` that is neither a table nor `nil` raises `bad argument #2 to 'setmetatable' (nil or table expected)`. A table whose metatable carries a `__metatable` field accepts the change, which [`setmetatable`](/manual/api#setmetatable) refuses with the error `cannot change a protected metatable`.

The following example gives every number a method and then removes it again.

```lus
debug.setmetatable(0, { __index = { double = function(n) return n * 2 end } })
print((21):double(), (1.5):double())      --> 42  3.0
debug.setmetatable(0, nil)
print(catch (21):double())                --> false  ...: attempt to index a number value
```

The metatable of a type is shared by every chunk in the state, including the standard library, so a change affects all code that runs afterwards. [`debug.getmetatable`](/manual/api#debug.getmetatable) reads a metatable without the protection.
