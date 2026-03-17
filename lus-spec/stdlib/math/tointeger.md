---
name: math.tointeger
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: x
    type: number
returns: integer|nil
---

Converts `x` to an integer if it is a number with an integer value. Returns `nil` if `x` is not an integer or not a number.
