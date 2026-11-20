---
name: worker.receive
module: worker
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: w1
    type: worker
vararg: true
returns: any
---

Performs a blocking selection over one or more workers. It waits until at least one worker has a message or reaches a terminal state, then returns one aligned value per argument. A ready message is deserialized, while a worker without a message contributes `nil`. A worker script error propagates from this call.

A worker ends once its script has returned and the coroutines that the script detached have ended (see `coroutine.detach`). The error of a detached coroutine that failed with nothing left to collect it is the error of the worker, and it propagates from this call like a script error.

`receive` is a suspension point. Inside a detached coroutine it suspends the coroutine while it waits, and anywhere else the detached coroutines of the state run while it waits.

```lus nocheck
local msg = worker.receive(w)
local m1, m2 = worker.receive(w1, w2)
```
