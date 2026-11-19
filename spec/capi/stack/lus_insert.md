---
name: "lus_insert"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_insert(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
---

Moves the top value into `idx` and shifts the values from `idx` upward by one slot. The number of values stays the same.

The following lines put a function below the two arguments that are already on the stack, ready for `lus_pcall`.

```c
lus_getglobal(L, "print");
lus_insert(L, -3);
lus_pcall(L, 2, 0);
```
