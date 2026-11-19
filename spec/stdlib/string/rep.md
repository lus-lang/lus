---
name: string.rep
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: s
    type: string
  - name: n
    type: integer
  - name: sep
    type: string
    optional: true
returns: string
---

Return a string consisting of `n` copies of `s`, separated by `sep` (empty string by default).
