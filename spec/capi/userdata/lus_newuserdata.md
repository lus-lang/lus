---
name: "lus_newuserdata"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void *lus_newuserdata(lus_State *L, size_t size)"
params:
  - name: L
    type: "lus_State*"
  - name: size
    type: "size_t"
returns:
  - type: "void*"
---

Pushes a new userdata with a data block of `size` bytes and returns the address of the block. The block is aligned to 8 bytes, its initial contents are unspecified, and it lives until the userdata is collected. When memory runs out, the call returns `NULL` and pushes the error value in place of the userdata.

A metatable gives the userdata methods and a finalizer. The following constructor makes a `Counter` and gives it the metatable registered under that name.

```c
typedef struct Counter {
  lus_Integer value;
} Counter;

static int counter_new(lus_State *L) {
  Counter *c = lus_newuserdata(L, sizeof *c);
  if (c == NULL)
    return lus_error(L);
  c->value = 0;
  if (lus_newmetatable(L, "Counter") == LUS_ERROR)
    return lus_error(L);
  if (lus_setmetatable(L, -2) != LUS_OK)
    return lus_error(L);
  return 1;
}
```
