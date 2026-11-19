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

Sets the metatable of table `t` to `metatable`. If `metatable` is `nil`, removes the metatable. Raises an error if the existing metatable has a `__metatable` field. Returns `t`.
