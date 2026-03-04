---
name: table.concat
module: table
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: list
    type: table
  - name: sep
    type: string
    optional: true
  - name: i
    type: integer
    optional: true
  - name: j
    type: integer
    optional: true
returns: string
---

Concatenate the string or number elements of table `list`, separated by `sep` (empty string by default), from index `i` to `j`.
