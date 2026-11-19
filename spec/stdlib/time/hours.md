---
name: time.hours
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

Returns a `duration` of `n` hours. A concise alternative to `time.duration{ hours = n }` for single-unit spans.

```lus
local timeout = time.hours(5)
```
