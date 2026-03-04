---
name: string.sub
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
  - name: j
    type: integer
    optional: true
returns: string
---

Return the substring of `s` from position `i` to `j` (inclusive). Negative indices count from the end of the string. Default for `j` is `-1` (end of string).
