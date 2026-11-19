---
name: ipairs
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: t
    type: table
returns: function
---

Returns an iterator function that traverses the integer keys of `t` in order, from `t[1]` up to the first absent index. Intended for use in `for` loops.
