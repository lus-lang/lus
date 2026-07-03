---
name: time.days
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

Returns a `duration` of `n` days. A concise alternative to `time.duration{ days = n }` for single-unit spans.

```lus
local timeout = time.days(5)
```
