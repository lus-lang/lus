---
name: coroutine.yield
module: coroutine
kind: function
since: 0.1.0
stability: stable
origin: lua
vararg: true
returns: any
---

Suspends the running coroutine. Arguments to `yield` become the extra return values of the `resume` that restarted this coroutine.
