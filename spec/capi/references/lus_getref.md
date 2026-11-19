---
name: "lus_getref"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_getref(lus_State *L, int ref)"
params:
  - name: L
    type: "lus_State*"
  - name: ref
    type: "int"
---

Pushes the value of a reference. `LUS_NOREF`, a released reference, and any other number that names no value push nil. The call never fails.

```c
static void fire(lus_State *L, int callback) {
  lus_getref(L, callback);
  lus_pushstring(L, "ready");
  if (lus_pcall(L, 1, 0) != LUS_OK)
    lus_pop(L, 1);
}
```
