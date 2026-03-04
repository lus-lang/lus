---
name: utf8.codepoint
module: utf8
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

Return the codepoints of all characters in `s` from position `i` to `j` (default `i = 1`, `j = i`).
