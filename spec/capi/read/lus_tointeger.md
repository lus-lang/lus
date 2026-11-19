---
name: "lus_tointeger"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "lus_Integer lus_tointeger(lus_State *L, int idx, int *isnum)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
  - name: isnum
    type: "int*"
returns:
  - type: "lus_Integer"
---

Returns the value at `idx` as an integer. Integers convert directly. A float, a bigint, or a string converts when it holds a number with an exact integer value in the 64 bit range, so `3.0`, `10n`, and `"0x10"` convert while `3.5` does not.

When `isnum` is not `NULL`, it receives 1 when the conversion succeeded and 0 otherwise. A failed conversion returns 0, so `isnum` tells a real zero apart from a failure.

```c
int ok;
lus_Integer n = lus_tointeger(L, 1, &ok);
if (!ok)
  return lus_errorf(L, "bad argument #1 (integer expected)");
```
