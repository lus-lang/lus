---
name: "lus_openlibs"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_openlibs(lus_State *L)"
params:
  - name: L
    type: "lus_State*"
returns:
  - type: "int"
    name: status
---

Opens every standard library into the global table and returns `LUS_OK`. On failure, such as when memory runs out, it returns the status and pushes the error value. On success the stack is unchanged.

The libraries that reach the file system, the network, processes, or the environment check permissions on every call, so opening them grants nothing by itself.
