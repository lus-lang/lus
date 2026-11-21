---
name: "lus_pending"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_pending(lus_State *L)"
params:
  - name: L
    type: "lus_State*"
returns:
  - type: "int"
    name: count
---

Returns the number of detached coroutines that have not ended.

A host with an event loop of its own uses the count to decide whether to keep calling `lus_runpending` with `wait` zero.

```c
while (lus_pending(L) > 0) {
  if (lus_runpending(L, 0) != LUS_OK) break;
  /* other work of the host */
}
```
