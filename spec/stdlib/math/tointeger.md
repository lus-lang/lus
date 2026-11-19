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

Converts `x` to an integer if its value is convertible to one, meaning a number of any subtype with an integral value that fits in 64 bits, or a string naming such a number. Returns `nil` when `x` cannot be converted.
