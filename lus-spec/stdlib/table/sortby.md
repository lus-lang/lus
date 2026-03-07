---
name: table.sortby
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
  - name: asc
    type: boolean
    optional: true
---

Sorts `array` in-place by the key returned by `keyfunc(element)`. When `asc` is `false`, sorts in descending order. Default is ascending. Returns nothing.
