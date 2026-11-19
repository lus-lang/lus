---
name: "lus_reject"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_reject(lus_State *L, const char *name)"
params:
  - name: L
    type: "lus_State*"
  - name: name
    type: "const char*"
returns:
  - type: "int"
    name: status
---

Rejects the capability `name`, such as `"exec"` or `"fs:write"`, and returns `LUS_OK`. A rejection is permanent. Every later grant of the capability fails, from the host and from scripts alike, and every check of it is denied. Rejecting a base capability also denies its subcapabilities.

A rejection by itself sets no ceiling, so it leaves scripts free to pledge everything else. When the host has already granted something, the rejection is added to the existing ceiling.

On failure the call returns `LUS_ERRRUN` or `LUS_ERRMEM` and pushes the error value. A rejection fails for an unknown capability and a sealed set.
