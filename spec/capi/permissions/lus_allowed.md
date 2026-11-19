---
name: "lus_allowed"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_allowed(lus_State *L, const char *capability, const char *value)"
params:
  - name: L
    type: "lus_State*"
  - name: capability
    type: "const char*"
  - name: value
    type: "const char*"
returns:
  - type: "int"
---

Returns 1 when the running code holds `capability` for `value` and 0 otherwise, with the same rules as `lus_require`. It never raises and leaves the stack unchanged, so it suits code that offers a reduced behavior instead of failing.
