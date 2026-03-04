---
name: lus_worker_pool_init
header: lworkerlib.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "void lus_worker_pool_init (lua_State *L)"
params:
  - name: L
    type: "lua_State*"
---

Initializes the global worker thread pool. Called automatically on first `worker.create()`.
