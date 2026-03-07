---
name: table.groupby
module: table
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: array
    type: table
  - name: keyfunc
    type: function
returns: table
---

Groups elements of `array` by the result of `keyfunc(element)`. Returns a new table where keys are the grouping results and values are tables of grouped elements.
