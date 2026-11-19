---
name: coroutine.status
module: coroutine
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: co
    type: thread
returns: string
---

Returns the status of coroutine `co` as a string: `"running"`, `"suspended"`, `"normal"`, or `"dead"`.
