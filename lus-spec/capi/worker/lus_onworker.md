---
name: lus_onworker
header: lworkerlib.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "void lus_onworker (lua_State *L, lus_WorkerSetup fn)"
params:
  - name: L
    type: "lua_State*"
  - name: fn
    type: lus_WorkerSetup
---

Registers a callback to be invoked when new worker states are created.
