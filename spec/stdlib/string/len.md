---
name: string.len
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: s
    type: string
returns: integer
---

Return the length of string `s` in characters. A character is one Unicode code point, so `string.len("héllo")` is 5. The `#` operator returns the same value.
