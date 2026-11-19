---
name: lus_worker_send
header: lua.h
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

Serializes the value at stack index `idx` and appends it to `w`'s inbox. Returns `1` on success and `0` when the value cannot be serialized, queue allocation fails, the worker is shutting down, or the handle is `NULL`. The function borrows `w` for the call.
