---
name: worker.send
module: worker
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: w
    type: worker
  - name: value
    type: any
---

Serializes `value` and appends it to worker `w`'s inbox. The worker receives the independent copy with `worker.peek`. Nil, booleans, numbers, strings, and tables can cross the boundary. Tables may nest up to 100 levels.
