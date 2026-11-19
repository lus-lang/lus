---
name: "lus_close"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_close(lus_State *L)"
params:
  - name: L
    type: "lus_State*"
---

Frees a state. Before it frees memory, it runs the finalizer of every object that still has one, so C resources held by userdata are released, then it stops the workers the state started and flushes buffered output.

`L` is the state that `lus_newstate` returned. Afterwards `L`, its coroutines, and every pointer obtained from them are invalid.
