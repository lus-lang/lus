---
name: vector.unpack
module: vector
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: v
    type: vector
  - name: offset
    type: integer
  - name: fmt
    type: string
returns: any
---

Unpacks values from the vector `v` starting at `offset`. Uses the same format string as `string.unpack`. Returns unpacked values followed by the next offset.

```lus
local a, b, c, nextpos = vector.unpack(v, 0, "I4I4I4")
```
