---
name: tostring
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: v
    type: any
returns: string
---

Converts `v` to a human-readable string. If `v` has a `__tostring` metamethod, calls it with `v` as argument and returns the result.
