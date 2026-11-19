---
name: lus_worker_receive
header: lua.h
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

Attempts to receive one message from `w` without blocking. On success it pushes the deserialized value on `L` and returns `1`. It returns `0` when no message is ready, the handle is `NULL`, or deserialization fails. The function borrows `w` for the call.
