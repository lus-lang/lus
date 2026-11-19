---
name: os.difftime
module: os
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: t2
    type: integer
  - name: t1
    type: integer
returns: number
---

Returns the difference `t2 - t1` in seconds, where `t1` and `t2` are values returned by `os.time`.
