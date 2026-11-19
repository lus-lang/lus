---
name: utf8.len
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
returns: integer|nil
---

Return the number of characters in `s` from character position `i` to `j`, so `utf8.len(s)` equals `#s`. A lone surrogate is invalid unless `lax` is true, and on failure the function returns `nil` plus the position of that character.
