---
name: string.pack
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: fmt
    type: string
vararg: true
returns: string
---

Return a binary string containing the values packed according to format string `fmt`. See `string.unpack` for format codes.
