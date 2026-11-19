---
name: "lus_traceback"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "const char *lus_traceback(lus_State *L)"
params:
  - name: L
    type: "lus_State*"
returns:
  - type: "const char*"
---

Returns the stack traceback of the error caught by the last `lus_pcall` on `L`, which `lus_dostring` and `lus_dofile` also use. It returns `NULL` when that call succeeded or when its error was raised without any Lus frame on the stack.

The text belongs to the state and stays valid until the next call of `lus_pcall` on `L`.

```c
if (lus_dostring(L, script) != LUS_OK) {
  const char *tb = lus_traceback(L);
  fprintf(stderr, "%s\n", lus_tostring(L, -1, NULL));
  if (tb != NULL)
    fprintf(stderr, "%s\n", tb);
  lus_pop(L, 1);
}
```
