---
name: lus_worker_receive
header: lworkerlib.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "int lus_worker_receive (lua_State *L, WorkerState *w)"
params:
  - name: L
    type: "lua_State*"
  - name: w
    type: "WorkerState*"
---

Receives a message from the worker's outbox. Pushes the message onto the stack.
