---
name: debug.setupvalue
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: f
    type: function
  - name: up
    type: integer
  - name: value
    type: any
returns: string|nil
---

Sets the value of upvalue `up` of function `f` to `value`. Returns the upvalue name, or `nil` for invalid indices.
