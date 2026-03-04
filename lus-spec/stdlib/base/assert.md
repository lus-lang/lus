---
name: assert
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: v
    type: any
  - name: message
    type: any
    optional: true
returns: any
---

Checks whether `v` is truthy. If so, returns all its arguments. Otherwise, raises an error with `message` (defaults to `"assertion failed!"`).
