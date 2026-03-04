---
name: math.random
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: m
    type: integer
    optional: true
  - name: n
    type: integer
    optional: true
returns: number
---

When called without arguments, returns a uniform pseudo-random float in [0,1). With one integer `m`, returns an integer in [1, m]. With two integers `m` and `n`, returns an integer in [m, n].
