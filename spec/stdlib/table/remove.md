---
name: table.remove
module: table
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: list
    type: table
  - name: pos
    type: integer
    optional: true
returns: any
---

Remove the element at position `pos` from `list`, shifting down subsequent elements. Default `pos` is `#list`, so it removes the last element. Returns the removed value.
