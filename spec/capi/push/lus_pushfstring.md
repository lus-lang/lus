---
name: "lus_pushfstring"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "static inline int lus_pushfstring(lus_State *L, const char *fmt, ...)"
params:
  - name: L
    type: "lus_State*"
  - name: fmt
    type: "const char*"
vararg: true
returns:
  - type: "int"
    name: status
---

Pushes a string built from `fmt` and the following arguments with the rules of the C `printf` family, and returns the status of the push. The header defines it inline on top of `lus_pushvfstring`, so every conversion of the C library is available.

The formatted text is validated like the argument of `lus_pushstring`, so the call pushes exactly one value in every case.

```c
if (lus_pushfstring(L, "%s has %d items", name, count) != LUS_OK)
  return lus_error(L);
```
