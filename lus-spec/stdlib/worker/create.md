---
name: worker.create
module: worker
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: path
    type: string
vararg: true
returns: worker
---

Spawns a new worker running the script at `path`. Optional varargs are serialized and can be received by the worker via `worker.peek()`. Returns a worker handle. Requires `load` and `fs:read` pledges.

```lus
local w = worker.create("worker.lus", "hello", 42)
-- worker can receive "hello" and 42 via worker.peek()
```
