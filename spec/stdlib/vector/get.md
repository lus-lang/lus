---
name: vector.get
module: vector
kind: function
since: 2.0.0
stability: stable
origin: lus
params:
  - name: v
    type: vector
  - name: offset
    type: integer
returns: integer|nil
---

Returns the byte at the zero-based `offset` of `v` as an integer from 0 to 255, or `nil` when `offset` lies outside the vector.
