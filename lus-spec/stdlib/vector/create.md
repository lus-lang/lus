---
name: vector.create
module: vector
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: capacity
    type: integer
  - name: fast
    type: boolean
    optional: true
returns: vector
---

Creates a new vector with the given `capacity` in bytes. If `fast` is true, the buffer is not zero-initialized (faster but contents are undefined).

```lus
local v = vector.create(1024)        -- zero-initialized
local v = vector.create(1024, true)  -- fast, uninitialized
```
