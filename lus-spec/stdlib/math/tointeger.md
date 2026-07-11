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

Converts `x` to an integer if its value is convertible to one, meaning a number with an integer value or a string naming such a number. Returns `nil` when `x` cannot be converted.
