---
name: rawget
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: t
    type: table
  - name: k
    type: any
returns: any
---

Gets the value of `t[k]` without invoking the `__index` metamethod.
