---
name: coroutine.create
module: coroutine
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: f
    type: function
returns: thread
---

Creates and returns a suspended coroutine from function `f`. `coroutine.resume` begins its execution.
