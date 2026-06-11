---
name: xpcall
module: base
kind: function
since: 0.1.0
stability: removed
origin: lua
params:
  - name: f
    type: function
  - name: msgh
    type: function
vararg: true
---

Removed — use the `catch` expression instead; pair it with `debug.traceback` when a traceback is needed.
