---
name: pcall
module: base
kind: function
since: 0.1.0
stability: removed
origin: lua
params:
  - name: f
    type: function
vararg: true
---

Removed — use the `catch` expression instead: `local ok, result = catch f(...)`.
