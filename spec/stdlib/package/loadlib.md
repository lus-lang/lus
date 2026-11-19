---
name: package.loadlib
module: package
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:read", "load"]
origin: lua
params:
  - name: libname
    type: string
  - name: funcname
    type: string
returns: function|nil
---

Reports that native C libraries are unavailable in Lus 2.0. It checks `fs:read` on `libname` and the `load` permission, then returns `nil`, a message, and the name of the failing phase. A host program adds native functions through the C embedding API in `lus.h`.
