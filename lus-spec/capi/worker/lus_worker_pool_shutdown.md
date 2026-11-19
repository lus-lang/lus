---
name: lus_worker_pool_shutdown
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: void lus_worker_pool_shutdown (void)
---

Shuts down the process-wide worker pool and joins its threads. The call affects workers created by every Lus state in the process, so embedders call it during coordinated process shutdown.
