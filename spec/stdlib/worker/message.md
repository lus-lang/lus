---
name: worker.message
module: worker
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: value
    type: any
---

Available inside a worker state. Serializes and appends `value` to the worker's outbox for the parent to receive with `worker.receive`.
