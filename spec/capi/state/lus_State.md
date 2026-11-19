---
name: "lus_State"
header: lus.h
kind: type
since: "2.0.0"
stability: stable
origin: lus
signature: "typedef struct lus_State lus_State;"
---

An interpreter state, or one of its coroutines. The structure is opaque, so a host only ever holds a pointer to it, and every function of `lus.h` takes that pointer as its first argument.

`lus_newstate` creates a state and `lus_close` frees it. A C function receives the state of the coroutine that calls it, which shares the global table, the registry, the references, and the permission policy of the main state. A state is used by one operating system thread at a time.
