---
name: table.move
module: table
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: a1
    type: table
  - name: f
    type: integer
  - name: e
    type: integer
  - name: t
    type: integer
  - name: a2
    type: table
    optional: true
returns: table
---

Copy elements from table `a1` positions `f` through `e` into table `a2` (defaults to `a1`) starting at position `t`. Returns `a2`.
