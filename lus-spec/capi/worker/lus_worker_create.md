---
name: lus_worker_create
header: lworkerlib.h
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

Creates a new worker running the script at `path`.
