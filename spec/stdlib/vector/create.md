---
name: vector.create
module: vector
kind: function
since: 0.1.0
stability: stable
origin: lus
fastcall: true
params:
  - name: capacity
    type: integer
  - name: fast
    type: boolean
    optional: true
returns: vector
---

Creates a new vector of `capacity` bytes, all set to zero. The optional `fast` flag is accepted and every vector starts zeroed regardless.

```lus
local v = vector.create(1024)
print(#v, vector.get(v, 0))   --> 1024  0
```
