---
name: lus_worker_status
header: lworkerlib.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "int lus_worker_status (WorkerState *w)"
params:
  - name: w
    type: "WorkerState*"
---

Returns the status of a worker (`LUS_WORKER_RUNNING`, `LUS_WORKER_DEAD`, etc.).
