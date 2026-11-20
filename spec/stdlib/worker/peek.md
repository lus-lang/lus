---
name: worker.peek
module: worker
kind: function
since: 0.1.0
stability: stable
origin: lus
returns: any
---

Available inside a worker state. Blocks until it can deserialize and return the next inbox value sent by the parent with `worker.send`.

`peek` is a suspension point. Inside a detached coroutine it suspends the coroutine while it waits, and anywhere else the detached coroutines of the worker run while it waits (see `coroutine.detach`).
