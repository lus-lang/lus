---
name: "lus_CFunction"
header: lus.h
kind: type
since: "2.0.0"
stability: stable
origin: lus
signature: "typedef int (*lus_CFunction)(lus_State *L);"
---

A function written in C. It receives its arguments at stack indices 1 through `lus_gettop(L)`, pushes its results, and returns how many it pushed. The results are the top values of its frame, and any values below them are discarded. Returning more results than the frame holds raises an error.

To raise an error, the function returns `LUS_ERROR`, which is what `lus_error`, `lus_errorstr`, and `lus_errorf` return. A function that receives a failed status from another call returns `lus_error(L)`, which raises the error value that the failed call left on the stack.

```c
/* add(a, b) returns a + b for two integers. */
static int add(lus_State *L) {
  int ok1, ok2;
  lus_Integer a = lus_tointeger(L, 1, &ok1);
  lus_Integer b = lus_tointeger(L, 2, &ok2);
  if (!ok1 || !ok2)
    return lus_errorf(L, "add expects two integers");
  lus_pushinteger(L, a + b);
  return 1;
}
```
