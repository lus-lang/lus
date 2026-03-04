---
name: debug.getlocal
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: f
    type: function|integer
  - name: local_
    type: integer
    optional: true
returns: string|nil
---

Returns the name and value of local variable `local` at stack level `f`. Returns `nil` if there is no local variable with that index. Negative indices access vararg arguments.
