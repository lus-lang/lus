---
name: lus_worker_retain
header: lua.h
kind: function
since: 1.7.0
stability: unstable
origin: lus
signature: "WorkerState *lus_worker_retain (WorkerState *w)"
params:
  - name: w
    type: "WorkerState*"
---

Adds one owned reference to `w` and returns the same opaque handle. Passing `NULL` returns `NULL` and performs no work. Match each successful retain with `lus_worker_release`.
