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

Blocking select-style receive from one or more workers. Blocks until at least one worker has a message. Returns one value per worker: the message if available, or `nil` if that worker has no message. Propagates worker errors.

```lus
local msg = worker.receive(w)
-- or multi-worker select:
local m1, m2 = worker.receive(w1, w2)
```
