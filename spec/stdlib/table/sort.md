---
name: table.sort
module: table
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: list
    type: table
  - name: comp
    type: function
    optional: true
---

Sort `list` elements in place. If `comp` is given, it must be a function that takes two elements and returns `true` when the first is less than the second. The sort is not stable.
