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

Creates a new coroutine from function `f` and returns it. Does not start execution; use `coroutine.resume` to begin.
