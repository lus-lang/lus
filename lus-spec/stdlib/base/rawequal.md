---
name: rawequal
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: v1
    type: any
  - name: v2
    type: any
returns: boolean
---

Checks equality of `v1` and `v2` without invoking the `__eq` metamethod. Returns `true` if they are primitively equal.
