---
name: "lus_pushcclosure"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_pushcclosure(lus_State *L, lus_CFunction f, int n)"
params:
  - name: L
    type: "lus_State*"
  - name: f
    type: "lus_CFunction"
  - name: n
    type: "int"
returns:
  - type: "int"
    name: status
---

Pops `n` values and pushes a C function that holds them as upvalues, then returns `LUS_OK`. The first popped value, the deepest one, becomes upvalue 1. The function reads them with `lus_getupvalue`.

On failure it returns `LUS_ERRMEM` and the error value replaces the `n` values.

```c
/* A counter that keeps its step in upvalue 1. */
static int step(lus_State *L) {
  lus_getupvalue(L, 1);
  return 1;
}

static int make_step(lus_State *L) {
  lus_pushinteger(L, 5);
  if (lus_pushcclosure(L, step, 1) != LUS_OK)
    return lus_error(L);
  return 1;
}
```
