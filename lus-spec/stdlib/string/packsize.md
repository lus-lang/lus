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

Return the size of the string that would result from `string.pack` with format `fmt`. The format must not contain variable-length options.
