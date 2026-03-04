---
name: debug.getuservalue
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: u
    type: userdata
  - name: n
    type: integer
    optional: true
returns: any
---

Returns the `n`-th user value associated with userdata `u`, plus a boolean indicating whether the userdata has that value.
