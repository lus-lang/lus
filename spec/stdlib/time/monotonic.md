---
name: time.monotonic
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
returns: instant
---

Returns a monotonic `instant` for timing durations. Monotonic instants never move backwards and are immune to wall-clock adjustments (NTP, DST), but they have no calendar meaning: they may only be subtracted from another monotonic reading to yield a `duration`. Formatting one or calling `:epoch()` raises an error.

```lus
local start = time.monotonic()
do_work()
print(`took {time.monotonic() - start}`)
```
