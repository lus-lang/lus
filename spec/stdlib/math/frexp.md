---
name: math.frexp
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: x
    type: number
returns: number
---

Returns `m` and `e` such that `x = m * 2^e`, where `m` is in [0.5, 1) and `e` is an integer.
