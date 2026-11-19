---
name: "lus_pushstring"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_pushstring(lus_State *L, const char *s)"
params:
  - name: L
    type: "lus_State*"
  - name: s
    type: "const char*"
returns:
  - type: "int"
    name: status
---

Pushes a copy of the zero terminated string `s`, or nil when `s` is `NULL`, and returns `LUS_OK`. The string must be well formed WTF-8, which is UTF-8 that also admits encoded surrogates. Other bytes give `LUS_ERRRUN` with an error message that names the offset of the first bad byte.

The call pushes exactly one value in every case: the string on success and the error value on failure. A C function therefore propagates a failure directly.

```c
if (lus_pushstring(L, name) != LUS_OK)
  return lus_error(L);
```
