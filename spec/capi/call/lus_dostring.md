---
name: "lus_dostring"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_dostring(lus_State *L, const char *src)"
params:
  - name: L
    type: "lus_State*"
  - name: src
    type: "const char*"
returns:
  - type: "int"
    name: status
---

Loads the zero terminated source `src` with the chunk name `"=(dostring)"` and calls it with no arguments, keeping every result. It returns the status of the load or of the call.

On success the results stay on the stack. On failure the stack holds one error value in their place, and error messages begin with `(dostring):` and the line number.
