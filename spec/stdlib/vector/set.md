---
name: vector.set
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
  - name: byte
    type: integer
---

Stores `byte`, an integer from 0 to 255, at the zero-based `offset` of `v`. An offset outside the vector or a value outside the byte range raises an error. `vector.resize` grows a vector before a write past its end.
