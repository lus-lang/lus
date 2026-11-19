---
name: "lus_collect"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_collect(lus_State *L)"
params:
  - name: L
    type: "lus_State*"
---

Runs a full garbage collection cycle, then runs the finalizers that the cycle made due. An error raised by a finalizer is discarded. The stack is unchanged.

The collector runs on its own as a program allocates, so a host calls `lus_collect` only to release resources at a moment of its choosing.
