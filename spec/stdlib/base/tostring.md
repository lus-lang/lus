---
name: tostring
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: v
    type: any
returns: string
---

Converts `v` to a human-readable string. If `v` has a `__tostring` metamethod, calls it with `v` as argument and returns the result. A bigint prints in decimal without its `n` suffix, and a decimal prints exactly its stored digits, so `tostring(1.50d)` is `"1.50"`.
