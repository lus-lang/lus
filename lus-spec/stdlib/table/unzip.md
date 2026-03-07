---
name: table.unzip
module: table
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: array_of_tuples
    type: table
returns:
  - type: table
    name: "..."
---

Splits a table of tuples into separate tables (inverse of `table.zip`). Returns multiple tables, one per position in the tuples. All tuples must have the same length.
