---
name: rawset
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: t
    type: T
  - name: k
    type: any
  - name: v
    type: any
generic: T
returns: T
---

Sets `t[k] = v` without invoking the `__newindex` metamethod. Returns `t`.
