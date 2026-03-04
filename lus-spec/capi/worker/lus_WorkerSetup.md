---
name: lus_WorkerSetup
header: lworkerlib.h
kind: type
since: 0.1.0
stability: stable
origin: lus
signature: "typedef void (*lus_WorkerSetup)(lua_State *parent, lua_State *worker);"
---

Callback type for worker state initialization. Called when a new worker is created, allowing embedders to configure the worker's Lua state.
