---
name: next
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: t
    type: table
  - name: k
    type: any
    optional: true
returns: any
---

Returns the next key--value pair after key `k` in table `t`. When called with `nil` as the second argument, returns the first pair. Returns `nil` when there are no more pairs. The traversal order is undefined.
