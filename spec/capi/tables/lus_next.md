---
name: "lus_next"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_next(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
---

Pops a key and pushes the key and value of the next field of the table at `idx`. It returns 1 when it pushed a pair and 0, pushing nothing, when the table has no field after the key. A traversal starts with a nil key.

It returns `LUS_ERROR` when the value at `idx` is not a table or the key is not in the table, and the error value then replaces the key.

The following loop prints every key of the table at index 1. It leaves the key on the stack for the next call and pops only the value.

```c
lus_pushnil(L);
while (lus_next(L, 1) == 1) {
  if (lus_type(L, -2) == LUS_TSTRING)
    printf("%s\n", lus_tostring(L, -2, NULL));
  lus_pop(L, 1);
}
```
