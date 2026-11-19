---
name: "lus_newmetatable"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_newmetatable(lus_State *L, const char *tname)"
params:
  - name: L
    type: "lus_State*"
  - name: tname
    type: "const char*"
returns:
  - type: "int"
---

Pushes the metatable registered under the type name `tname`, creating it when needed. A new metatable gets the field `__name = tname`, which `tostring` and error messages use to name the values that carry it.

It returns 1 when this call created the table and 0 when it already existed, so a library fills in its methods only once. When memory runs out it returns `LUS_ERROR` and pushes the error value in place of the table.

```c
static int counter_get(lus_State *L) {
  lus_Integer *v = lus_toudata(L, 1, "Counter");
  if (v == NULL)
    return lus_errorf(L, "bad argument #1 to 'get' (Counter expected)");
  lus_pushinteger(L, *v);
  return 1;
}

static int open_counter(lus_State *L) {
  int created = lus_newmetatable(L, "Counter");
  if (created == LUS_ERROR)
    return lus_error(L);
  if (created) {
    if (lus_newtable(L, 0, 1) != LUS_OK)
      return lus_error(L);
    if (lus_pushcfunction(L, counter_get) != LUS_OK)
      return lus_error(L);
    if (lus_setfield(L, -2, "get") != LUS_OK)
      return lus_error(L);
    if (lus_setfield(L, -2, "__index") != LUS_OK)
      return lus_error(L);
  }
  lus_pop(L, 1);
  return 0;
}
```
