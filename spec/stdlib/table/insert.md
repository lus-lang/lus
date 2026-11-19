---
name: table.insert
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
  - name: value
    type: any
    optional: true
---

Insert `value` at position `pos` in `list`, shifting up subsequent elements. If `pos` is omitted, appends to the end.
