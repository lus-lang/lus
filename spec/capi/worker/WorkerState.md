---
name: WorkerState
header: lua.h
kind: type
since: 0.1.0
stability: stable
origin: lus
signature: "typedef struct WorkerState WorkerState;"
---

An opaque worker handle. A successful `lus_worker_create` returns one owned reference. Retain the handle before sharing it with another owner and release every owned reference when it is no longer needed. An owned handle remains valid after its parent `lua_State` closes, although that close drains the associated worker.
