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

Returns the next key and value after key `k` in table `t`. When called with `nil` as the second argument, returns the first pair. A call after the final pair returns `nil`. The traversal order is undefined.
