---
name: utf8.codepoint
module: utf8
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: s
    type: string
  - name: i
    type: integer
    optional: true
  - name: j
    type: integer
    optional: true
  - name: lax
    type: boolean
    optional: true
returns: integer
---

Return the code points of all characters in `s` from character position `i` to `j` (default `i = 1`, `j = i`). A lone surrogate raises an error unless `lax` is true.
