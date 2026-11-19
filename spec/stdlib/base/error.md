---
name: error
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: message
    type: any
  - name: level
    type: integer
    optional: true
---

Raises an error with `message` as the error object. The `level` argument specifies where the error position points: 1 (default) is the caller, 2 is the caller's caller, and so on. Level 0 omits position information.
