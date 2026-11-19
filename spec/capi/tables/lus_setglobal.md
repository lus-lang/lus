---
name: "lus_setglobal"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_setglobal(lus_State *L, const char *name)"
params:
  - name: L
    type: "lus_State*"
  - name: name
    type: "const char*"
returns:
  - type: "int"
    name: status
---

Pops the top value into the global `name` and returns `LUS_OK`. On failure the call returns the status and the error value replaces the popped value.

The following lines register a C function as the global `greet`.

```c
static int greet(lus_State *L) {
  lus_pushstring(L, "hello");
  return 1;
}

static int open_greet(lus_State *L) {
  if (lus_pushcfunction(L, greet) != LUS_OK)
    return lus_error(L);
  if (lus_setglobal(L, "greet") != LUS_OK)
    return lus_error(L);
  return 0;
}
```
