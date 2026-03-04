---
name: math.atan
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: y
    type: number
  - name: x
    type: number
    optional: true
returns: number
---

Returns the arc tangent of `y/x` in radians, using the signs of both arguments to determine the quadrant. `x` defaults to 1.
