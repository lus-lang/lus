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

Returns the name and value of local variable `local` at stack level `f`. An index past the available locals returns `nil`. Negative indices access vararg arguments.
