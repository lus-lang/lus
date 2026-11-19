---
name: table.unpack
module: table
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: list
    type: table
  - name: i
    type: integer
    optional: true
  - name: j
    type: integer
    optional: true
returns: any
---

Return the elements from table `list` from index `i` to `j`. Defaults to `i = 1` and `j = #list`.
