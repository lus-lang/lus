---
name: string.packsize
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: fmt
    type: string
returns: integer
---

Return the size in bytes of the vector that `string.pack` produces with format `fmt`. The format must not contain variable-length options.
