---
name: table.map
module: table
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: array
    type: table
  - name: func
    type: function
returns: table
---

Applies `func` to each element of `array`, returning a new table of results. The function receives `(element, index)` as arguments. The original table is not modified.
