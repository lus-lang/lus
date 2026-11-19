---
name: "lus_pcall"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_pcall(lus_State *L, int nargs, int nresults)"
params:
  - name: L
    type: "lus_State*"
  - name: nargs
    type: "int"
  - name: nresults
    type: "int"
returns:
  - type: "int"
    name: status
---

Calls a function in protected mode. The caller pushes the function, then `nargs` arguments, then calls `lus_pcall`.

On success the function and its arguments are replaced by `nresults` results and the call returns `LUS_OK`. Missing results are filled with nil and extra results are dropped. `LUS_MULTRET` keeps every result, and `lus_gettop` then tells how many there are.

On failure the function and its arguments are replaced by the error value, which can be of any type, and the call returns `LUS_ERRRUN`, or `LUS_ERRMEM` when memory ran out. Calling a value that is not a function and has no `__call` metamethod is a runtime error. The values below the function are never touched, and `lus_traceback` returns the traceback of the error.

```c
lus_getglobal(L, "string");
lus_getfield(L, -1, "rep");
lus_pushstring(L, "ab");
lus_pushinteger(L, 3);
if (lus_pcall(L, 2, 1) == LUS_OK)
  printf("%s\n", lus_tostring(L, -1, NULL));
else
  fprintf(stderr, "%s\n", lus_tostring(L, -1, NULL));
lus_pop(L, 2);
```
