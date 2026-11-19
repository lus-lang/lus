---
name: "lus_CapMatch"
header: lus.h
kind: type
since: "2.0.0"
stability: stable
origin: lus
signature: "typedef int (*lus_CapMatch)(void *ud, const char *granted, const char *requested);"
---

Decides whether the granted value of a `LUS_CAP_CUSTOM` capability covers a requested value. It returns a value other than zero to allow the request. `ud` is the pointer given in the `lus_Capability` declaration, and both strings are zero terminated copies that live for the duration of the call.

The function runs during permission checks and must not call back into the state.

```c
/* A grant of "N" allows any request of at most N units. */
static int quota_match(void *ud, const char *granted, const char *requested) {
  (void)ud;
  return atoll(requested) <= atoll(granted);
}
```
