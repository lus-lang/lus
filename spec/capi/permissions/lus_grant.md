---
name: "lus_grant"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_grant(lus_State *L, const char *spec)"
params:
  - name: L
    type: "lus_State*"
  - name: spec
    type: "const char*"
returns:
  - type: "int"
    name: status
---

Applies one host permission with the syntax of [`pledge`](/manual/permissions) and returns `LUS_OK`. A spec is `name`, `name:sub`, or either one followed by `=value`, such as `"network"`, `"fs:read=/srv/data/**"`, or `"env=HOME"`. A spec that starts with `~` rejects the capability like `lus_reject`, the spec `"seal"` seals the set like `lus_seal`, and the spec `"all"`, which only the host can grant, allows every capability.

Grants accumulate. A grant without a value allows every value of the capability, and each grant with a value adds one more allowed pattern. A grant of a base capability covers its subcapabilities, so `"network=example.com"` also allows `network:http` for that host. Values of path capabilities must be absolute or start with `.`, and they are resolved to canonical paths when they are granted.

Every grant is also added to the ceiling for script pledges. The ceiling holds only what the host decided, so what a script pledged earlier never widens it. Once the host has granted anything, a script can only pledge what that ceiling covers, unless a [request hook](#lus_onrequest) decides otherwise.

On failure the call returns `LUS_ERRRUN` and pushes the error value. A grant fails for an unknown capability or subcapability, an invalid value, a capability that was rejected, and a sealed set. On success the stack is unchanged.

```c
if (lus_grant(L, "fs:read=/srv/data/**") != LUS_OK ||
    lus_grant(L, "network:http=api.example.com") != LUS_OK ||
    lus_reject(L, "exec") != LUS_OK ||
    lus_seal(L) != LUS_OK) {
  fprintf(stderr, "%s\n", lus_tostring(L, -1, NULL));
  lus_pop(L, 1);
}
```
