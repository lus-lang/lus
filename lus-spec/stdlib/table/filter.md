---
name: table.filter
module: table
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: array
    type: table
  - name: predicate
    type: function
returns: table
---

Returns a new table containing only elements of `array` for which `predicate(element)` returns a truthy value. The original table is not modified. The result is a dense sequence.
