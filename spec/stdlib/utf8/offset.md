---
name: utf8.offset
module: utf8
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: s
    type: string
  - name: n
    type: integer
  - name: i
    type: integer
    optional: true
returns: integer|nil
---

Return the character position of the `n`-th character, counting from character position `i` (default 1 for positive `n`, `#s + 1` for non-positive). Each character occupies exactly one position, so the result is plain position arithmetic checked against the bounds of `s`.
