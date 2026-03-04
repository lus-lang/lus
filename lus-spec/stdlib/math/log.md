---
name: math.log
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: x
    type: number
  - name: base
    type: number
    optional: true
returns: number
---

Returns the logarithm of `x` in the given `base`. The default base is *e* (natural logarithm).
