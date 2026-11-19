---
name: "lus_getglobal"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_getglobal(lus_State *L, const char *name)"
params:
  - name: L
    type: "lus_State*"
  - name: name
    type: "const char*"
returns:
  - type: "int"
    name: status
---

Pushes the value of the global `name` and returns `LUS_OK`. A missing global pushes nil. The lookup honors metamethods of the global table, so on failure the call returns the status and pushes the error value in place of the result.
