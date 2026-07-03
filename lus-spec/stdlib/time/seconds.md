---
name: time.seconds
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
params:
  - name: n
    type: integer
returns: duration
---

Returns a `duration` of `n` seconds. A concise alternative to `time.duration{ seconds = n }` for single-unit spans.

```lus
local timeout = time.seconds(5)
```
