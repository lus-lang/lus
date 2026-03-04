---
name: lus_worker_send
header: lworkerlib.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "int lus_worker_send (lua_State *L, WorkerState *w, int idx)"
params:
  - name: L
    type: "lua_State*"
  - name: w
    type: "WorkerState*"
  - name: idx
    type: int
---

Sends the value at stack index `idx` to the worker's inbox.
