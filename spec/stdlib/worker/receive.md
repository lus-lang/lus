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

```lus nocheck
local msg = worker.receive(w)
local m1, m2 = worker.receive(w1, w2)
```
