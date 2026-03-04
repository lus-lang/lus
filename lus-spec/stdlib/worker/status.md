---
name: worker.status
module: worker
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: w
    type: worker
returns: string
---

Returns the status of worker `w`: `"running"` if the worker is still executing, or `"dead"` if it has finished or errored.
