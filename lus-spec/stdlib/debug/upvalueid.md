---
name: debug.upvalueid
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: f
    type: function
  - name: n
    type: integer
returns: userdata
---

Returns a unique identifier (light userdata) for upvalue `n` of function `f`. This can be used to check whether different closures share upvalues.
