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

Sends `value` to worker `w`'s inbox. The worker can receive it via `worker.peek()`. Values are deep-copied.
