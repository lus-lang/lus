---
name: lus_onworker
header: lua.h
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

Registers `fn` as the setup callback for workers created by `L`. Registration belongs to that global state. The callback function pointer must remain valid while workers can be created from the state.
