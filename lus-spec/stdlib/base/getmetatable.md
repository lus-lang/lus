---
name: getmetatable
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: object
    type: any
returns: table|nil
---

Returns the metatable of `object`. If the metatable has a `__metatable` field, returns that value instead. Returns `nil` if the object has no metatable.
