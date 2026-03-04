---
name: utf8.offset
module: utf8
kind: function
since: 0.1.0
stability: stable
origin: lua
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

Return the byte position of the `n`-th UTF-8 character, counting from byte position `i` (default 1 for positive `n`, `#s + 1` for non-positive).
