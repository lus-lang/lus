---
name: debug.setmetatable
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: value
    type: any
  - name: t
    type: table|nil
returns: any
---

Sets the metatable of `value` to `t` (which can be `nil`). Returns `value`.
