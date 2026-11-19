---
name: debug.getmetatable
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: value
    type: any
returns: table|nil
---

Returns the metatable of `value` without checking `__metatable`.
