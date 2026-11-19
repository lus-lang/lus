---
name: debug.setlocal
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: level
    type: integer
  - name: local_
    type: integer
  - name: value
    type: any
returns: string|nil
---

Sets the value of local variable `local` at stack level `level` to `value`. Returns the variable name, or `nil` if the index is invalid.
