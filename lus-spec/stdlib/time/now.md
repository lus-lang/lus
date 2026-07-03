---
name: time.now
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
returns: instant
---

Returns an `instant` for the current point in time, read from the system wall clock (UTC).

```lus
local n = time.now()
print(n:iso())          -- "2026-07-02T15:04:05Z"
print(n:epoch())        -- integer Unix seconds
```
