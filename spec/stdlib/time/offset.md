---
name: time.offset
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
params:
  - name: seconds
    type: integer
returns: zone
---

Returns a fixed-offset `zone` at `seconds` east of UTC (negative for west), for cases where a full IANA zone is unnecessary or unavailable. Its `:name()` is the formatted offset, e.g. `"-04:00"`. Unlike a named zone, a fixed offset never varies with the instant.

```lus
local z = time.offset(-5 * 3600)   -- UTC-05:00
```
