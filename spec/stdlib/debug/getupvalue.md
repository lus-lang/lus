---
name: debug.getupvalue
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
returns: string|nil
---

Returns the name and value of upvalue `up` of function `f`. Returns `nil` for invalid indices.
