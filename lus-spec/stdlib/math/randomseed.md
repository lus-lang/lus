---
name: math.randomseed
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: x
    type: integer
    optional: true
  - name: y
    type: integer
    optional: true
---

Sets `x` as the seed for the pseudo-random generator. When called without arguments, seeds with a system-dependent value. Equal seeds produce equal sequences.
