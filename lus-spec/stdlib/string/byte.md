---
name: string.byte
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: s
    type: string
  - name: i
    type: integer
    optional: true
  - name: j
    type: integer
    optional: true
returns: integer
---

Return the byte values of characters `s[i]` through `s[j]`. Defaults to `i = 1` and `j = i`.
