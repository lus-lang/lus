---
name: package.loadlib
module: package
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: libname
    type: string
  - name: funcname
    type: string
returns: function|nil
---

Dynamically loads C library `libname`. If `funcname` is `"*"`, links the library globally. Otherwise, returns the C function `funcname` from the library. Returns `nil` plus an error message on failure.
