---
name: debug.traceback
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: message
    type: any
    optional: true
  - name: level
    type: integer
    optional: true
returns: string
---

Returns a traceback string of the call stack. The optional `message` is prepended. The `level` argument specifies where to start the traceback (default 1).
