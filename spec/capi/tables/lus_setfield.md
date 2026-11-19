---
name: "lus_setfield"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_setfield(lus_State *L, int idx, const char *k)"
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

Does `t[k] = v`, where `t` is the value at `idx`, `k` is a zero terminated string, and `v` is the top value, and returns `LUS_OK`. The assignment honors `__newindex`.

On success `v` is popped. On failure the call returns the status and the error value replaces `v` on the stack.

The following lines build the table `{ x = 1, y = 2 }`.

```c
lus_newtable(L, 0, 2);
lus_pushinteger(L, 1);
lus_setfield(L, -2, "x");
lus_pushinteger(L, 2);
lus_setfield(L, -2, "y");
```
