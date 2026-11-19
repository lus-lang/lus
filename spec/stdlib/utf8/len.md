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
returns: integer|nil
---

Return the number of UTF-8 characters in `s` from position `i` to `j`. Returns `nil` plus the position of the first invalid byte on failure.
