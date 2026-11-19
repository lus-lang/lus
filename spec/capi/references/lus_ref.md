---
name: "lus_ref"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_ref(lus_State *L)"
params:
  - name: L
    type: "lus_State*"
returns:
  - type: "int"
    name: ref
---

Pops the top value and returns a reference to it, a positive integer that keeps the value alive until `lus_unref` releases it. Nil gives `LUS_NOREF`. When memory runs out, the call returns `LUS_ERROR` and the error value replaces the popped value.

References belong to the state, so a reference made in one C function stays valid in every later call and in every coroutine of the state. The numbers of released references are reused.

```c
static int callback = LUS_NOREF;

/* on(fn) keeps fn for later. */
static int on(lus_State *L) {
  lus_unref(L, callback);
  lus_pushvalue(L, 1);
  callback = lus_ref(L);
  if (callback == LUS_ERROR) {
    callback = LUS_NOREF;
    return lus_error(L);
  }
  return 0;
}
```
