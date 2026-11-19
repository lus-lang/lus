---
name: "lus_rawgeti"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_rawgeti(lus_State *L, int idx, lus_Integer n)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
  - name: n
    type: "lus_Integer"
returns:
  - type: "int"
    name: type
---

Pushes the value of `t[n]` without calling metamethods, where `t` is the table at `idx`, and returns the [type code](#LUS_T*) of the pushed value. A value at `idx` that is not a table gives nil. The call never fails.

The following loop reads a sequence until its first nil.

```c
for (lus_Integer i = 1; lus_rawgeti(L, 1, i) != LUS_TNIL; i++) {
  printf("%lld\n", (long long)lus_tointeger(L, -1, NULL));
  lus_pop(L, 1);
}
lus_pop(L, 1);
```
