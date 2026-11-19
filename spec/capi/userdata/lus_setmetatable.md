---
name: "lus_setmetatable"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_setmetatable(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
    name: status
---

Pops a table or nil and makes it the metatable of the table or userdata at `idx`, then returns `LUS_OK`. Nil removes the metatable. The call ignores the `__metatable` field.

When the metatable has a `__gc` field at this moment, its function becomes the finalizer of the object. The finalizer receives the object as its only argument and runs at most once, after the object becomes unreachable or when the state closes. A `__gc` field added to the metatable later does not register a finalizer.

The call returns `LUS_ERRRUN` when the popped value is neither a table nor nil, or when the value at `idx` is neither a table nor a userdata. The error value then replaces the popped value.

```c
/* The finalizer releases the resource that the block points to. */
static int file_gc(lus_State *L) {
  FILE **f = lus_toudata(L, 1, "File");
  if (f != NULL && *f != NULL) {
    fclose(*f);
    *f = NULL;
  }
  return 0;
}
```
