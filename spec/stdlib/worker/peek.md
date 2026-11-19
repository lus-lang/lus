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
