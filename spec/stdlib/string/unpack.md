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
  - name: data
    type: vector|string
  - name: pos
    type: integer
    optional: true
returns: any
---

Return the values packed in `data` according to format `fmt`, starting at byte position `pos` (default 1). `data` is usually the vector that `string.pack` returned. A string is read through its WTF-8 bytes. Also returns the position after the last read byte.
