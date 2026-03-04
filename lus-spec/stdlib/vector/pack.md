---
name: vector.pack
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
vararg: true
---

Packs values into the vector `v` starting at `offset`. Uses the same format string as `string.pack`.

```lus
local v = vector.create(16)
vector.pack(v, 0, "I4I4I4", 1, 2, 3)
```
