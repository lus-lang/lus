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

`package.loadlib(libname, funcname)` reports that native C libraries are unavailable in Lus 2.0 and returns `nil`, a message, and the name of the failing phase.

The parameter `libname` is the path of a native library, and `funcname` is the name of a function in it. Both must be strings. The results are always `nil`, a message, and the phase `"open"`. The message is `native C libraries are unavailable in Lus 2.0` when `libname` exists, and `cannot open PATH: REASON` when it does not.

`package.loadlib` first requires `fs:read` for `libname` and then the `load` permission. A missing permission raises `permission "fs:read" denied for 'PATH'` or `permission "load" denied`.

```lus
pledge("fs:read", "load")
print(package.loadlib("missing.so", "luaopen_missing"))
--> nil  cannot open missing.so: No such file or directory  open
```

A host program adds native functions through the C embedding API in `lus.h`, as [Embedding Lus](/manual/guide#embedding-lus) describes. [`package.cpath`](/manual/api#package.cpath) describes how `require` treats native modules.
