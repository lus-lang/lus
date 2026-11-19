---
name: worker.create
module: worker
kind: function
since: 0.1.0
stability: stable
pledges: ["load", "fs:read"]
origin: lus
params:
  - name: path
    type: string
vararg: true
returns: worker
---

Spawns a new worker running the script at `path`. Optional varargs are serialized and become the script's initial `...` values. Returns a worker handle. Requires `load` and authorized `fs:read` pledges for the script path.

```lus
local w = worker.create("worker.lus", "hello", 42)
-- worker.lus begins with: local greeting, number = ...
```
