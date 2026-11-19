---
name: "lus_error"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_error(lus_State *L)"
params:
  - name: L
    type: "lus_State*"
returns:
  - type: "int"
---

Pops the top value and makes it the pending error, then returns `LUS_ERROR`. The error value can be of any type. An empty frame makes the error nil.

The pending error is raised when the running C function returns `LUS_ERROR`. That makes `return lus_error(L)` the way to pass on the error value that a failed call left on the stack, and the way to raise a value the function built itself.

```c
/* fail() raises the table { code = 404 }. */
static int fail(lus_State *L) {
  if (lus_newtable(L, 0, 1) != LUS_OK)
    return lus_error(L);
  lus_pushinteger(L, 404);
  if (lus_setfield(L, -2, "code") != LUS_OK)
    return lus_error(L);
  return lus_error(L);
}
```
