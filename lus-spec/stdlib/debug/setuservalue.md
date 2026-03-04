---
name: debug.setuservalue
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: u
    type: userdata
  - name: value
    type: any
  - name: n
    type: integer
    optional: true
returns: userdata
---

Sets the `n`-th user value associated with userdata `u` to `value`. Returns `u`.
