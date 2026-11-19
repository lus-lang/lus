---
name: lus_worker_release
header: lua.h
kind: function
since: 1.7.0
stability: unstable
origin: lus
signature: "void lus_worker_release (WorkerState *w)"
params:
  - name: w
    type: "WorkerState*"
---

Releases one owned reference to `w`. The final release destroys the handle after its runtime references are complete. Passing `NULL` performs no work.
