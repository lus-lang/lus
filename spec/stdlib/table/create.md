---
name: table.create
module: table
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: narray
    type: integer
  - name: nhash
    type: integer
    optional: true
returns: table
---

Create a new table with pre-allocated space for `narray` array elements and `nhash` hash elements. Useful for performance when the final table size is known.
