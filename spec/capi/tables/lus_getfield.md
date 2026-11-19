---
name: "lus_getfield"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_getfield(lus_State *L, int idx, const char *k)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
  - name: k
    type: "const char*"
returns:
  - type: "int"
    name: status
---

Pushes `t[k]`, where `t` is the value at `idx` and `k` is a zero terminated string, and returns `LUS_OK`. The lookup honors `__index`, so `t` can be any value that can be indexed and the call can fail.

On failure it returns the status and pushes the error value in place of the result, so the stack grows by one value in every case. Indexing nil, for example, gives `LUS_ERRRUN` with the message `attempt to index a nil value`.

```c
if (lus_getfield(L, 1, "width") != LUS_OK)
  return lus_error(L);
lus_Integer width = lus_tointeger(L, -1, NULL);
lus_pop(L, 1);
```
