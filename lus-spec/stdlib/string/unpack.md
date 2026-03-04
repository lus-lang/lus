---
name: string.unpack
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: fmt
    type: string
  - name: s
    type: string
  - name: pos
    type: integer
    optional: true
returns: any
---

Return the values packed in string `s` according to format `fmt`, starting at position `pos` (default 1). Also returns the position after the last read byte.
