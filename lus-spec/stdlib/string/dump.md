---
name: string.dump
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: function
    type: function
  - name: strip
    type: boolean
    optional: true
returns: string
---

Return a binary string containing a serialized representation of `function`, so that a later `load` on this string returns a copy of the function. If `strip` is true, debug information is omitted.
