---
name: math.type
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: x
    type: any
returns: string
---

Returns `"integer"` if `x` is an integer, `"float"` if it is a float, or `nil` if `x` is not a number.
