---
name: rawlen
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: v
    type: table|string
returns: integer
---

Returns the length of `v` without invoking the `__len` metamethod. `v` must be a table or string.
