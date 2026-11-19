---
name: lus_worker_create
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "WorkerState *lus_worker_create (lua_State *L, const char *path)"
params:
  - name: L
    type: "lua_State*"
  - name: path
    type: "const char*"
---

Creates a worker associated with `L` and schedules the script at `path`. Success returns one owned reference to an opaque `WorkerState`. Release that reference with `lus_worker_release`. A script open or execution failure is reported asynchronously through worker status. `NULL` reports a setup, allocation, or enqueue failure.
