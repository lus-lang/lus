---
name: string.byte
module: string
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
returns: integer
---

Return the code points of the characters `s[i]` through `s[j]`. Defaults to `i = 1` and `j = i`. Positions count characters, so `string.byte("é")` is 233. The bytes of a string are available through `vector.fromstring`.
