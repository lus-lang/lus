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

In a coroutine given to `coroutine.detach`, `yield` lets the other detached coroutines run. The runtime resumes the coroutine on its next turn, the arguments are dropped, and `yield` returns no values.
