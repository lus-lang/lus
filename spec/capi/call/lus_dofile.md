---
name: "lus_dofile"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_dofile(lus_State *L, const char *path)"
params:
  - name: L
    type: "lus_State*"
  - name: path
    type: "const char*"
returns:
  - type: "int"
    name: status
---

Loads the file at `path` with `lus_loadfile` and calls it with no arguments, keeping every result. It returns the status of the load or of the call.

On success the results stay on the stack. On failure the stack holds one error value in their place.
