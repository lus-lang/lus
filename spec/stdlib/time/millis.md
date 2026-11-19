---
name: time.millis
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

Returns a `duration` of `n` millis. A concise alternative to `time.duration{ millis = n }` for single-unit spans.

```lus
local timeout = time.millis(5)
```
