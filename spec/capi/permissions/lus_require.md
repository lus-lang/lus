---
name: "lus_require"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_require(lus_State *L, const char *capability, const char *value)"
params:
  - name: L
    type: "lus_State*"
  - name: capability
    type: "const char*"
  - name: value
    type: "const char*"
returns:
  - type: "int"
    name: status
---

Checks that the running code holds `capability`, such as `"network:http"`, for `value`, and returns `LUS_OK` when it does. `value` is `NULL` for a check that names no value. The check covers the grants of the host and the pledges of scripts.

When the check fails, the call pushes the standard permission error and returns `LUS_ERRRUN`. The message is `permission "store:read" denied for 'secrets/key'`, or `permission "store:read" denied` without a value. A C function propagates it directly.

```c
static int store_get(lus_State *L) {
  const char *key = lus_tostring(L, 1, NULL);
  if (key == NULL)
    return lus_errorf(L, "bad argument #1 to 'get' (string expected)");
  if (lus_require(L, "store:read", key) != LUS_OK)
    return lus_error(L);
  return lus_pushfstring(L, "value of %s", key) == LUS_OK ? 1 : lus_error(L);
}
```

A capability that nothing declared is always denied. A grant that is restricted to values allows a check that names no value, and a rejection denies every check of the capability.
