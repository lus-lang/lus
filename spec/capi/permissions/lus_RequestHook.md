---
name: "lus_RequestHook"
header: lus.h
kind: type
since: "2.0.0"
stability: stable
origin: lus
signature: "typedef int (*lus_RequestHook)(void *ud, lus_State *L, const char *capability, const char *value);"
---

Decides a script pledge that the host ceiling does not cover. It receives the pointer given to `lus_onrequest`, the state of the pledging script, the capability such as `"fs:read"`, and the requested value, which is `NULL` when the pledge names none. It returns a value other than zero to allow the grant, and the pledge then succeeds as if the host had granted it.

Both strings are copies that live for the duration of the call. The hook can use the stack of `L`, and the stack top is restored when it returns.
