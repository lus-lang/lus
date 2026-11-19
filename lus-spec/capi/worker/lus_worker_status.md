---
name: lus_worker_status
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "int lus_worker_status (WorkerState *w)"
params:
  - name: w
    type: "WorkerState*"
---

Returns the current `LUS_WORKER_*` status of `w`. A caller-owned reference keeps the opaque handle valid after its parent state closes. A `NULL` handle reports `LUS_WORKER_DEAD`.
