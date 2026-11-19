---
name: "lus_toudata"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void *lus_toudata(lus_State *L, int idx, const char *tname)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
  - name: tname
    type: "const char*"
returns:
  - type: "void*"
---

Returns the data block of the userdata at `idx` when its metatable is the one registered under `tname`, and `NULL` otherwise. It is the type check that C methods use on their receiver, since a script cannot forge the registered metatable.
