---
name: "lus_type"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_type(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
---

Returns the [type code](#LUS_T*) of the value at `idx`, or `LUS_TNONE` when the index names no value.

The following function accepts a number or a string and rejects every other value.

```c
static int describe(lus_State *L) {
  switch (lus_type(L, 1)) {
  case LUS_TNUMBER:
  case LUS_TSTRING:
    return lus_stringify(L, 1) == LUS_OK ? 1 : lus_error(L);
  default:
    return lus_errorf(L, "bad argument #1 (number or string expected, got %s)",
                      lus_typename(lus_type(L, 1)));
  }
}
```
