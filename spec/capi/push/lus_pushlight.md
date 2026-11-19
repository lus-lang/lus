---
name: "lus_pushlight"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_pushlight(lus_State *L, void *p)"
params:
  - name: L
    type: "lus_State*"
  - name: p
    type: "void*"
---

Pushes a light value that holds the raw host pointer `p`. A light value is never collected, so the host owns what `p` points to. Two light values are equal when they hold the same pointer, which makes them good table keys for host data. `lus_tolight` reads the pointer back.
