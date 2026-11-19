---
name: "lus_getupvalue"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_getupvalue(lus_State *L, int i)"
params:
  - name: L
    type: "lus_State*"
  - name: i
    type: "int"
---

Pushes upvalue `i` of the running C closure, counting from 1. It pushes nil when the running function has no such upvalue, and also when it is called outside a C function.

The upvalues of a C closure are fixed when it is created. A closure that needs changing state keeps a table in an upvalue and changes its fields.
