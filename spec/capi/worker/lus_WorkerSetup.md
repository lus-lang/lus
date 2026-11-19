---
name: lus_WorkerSetup
header: lua.h
kind: type
since: 0.1.0
stability: stable
origin: lus
signature: "typedef void (*lus_WorkerSetup)(lua_State *parent, lua_State *worker);"
---

Callback type for worker state initialization. The runtime calls it after creating `worker` and before loading its script. `parent` identifies the state that created the worker. Both pointers are borrowed for the callback duration.
