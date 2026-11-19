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
returns: vector
---

Return a vector containing the values packed according to format string `fmt`. Packed data is raw bytes, so the result is a vector. See `string.unpack` for format codes, and `vector.tostring` to decode packed text.
