---
name: time
module: time
kind: module
since: 1.7.0
stability: unstable
origin: lus
---

The `time` module: date, time, and duration handling. It provides three immutable value types:

- **`instant`** - an absolute point on the UTC timeline (second + nanosecond precision).
- **`duration`** - a signed span of time.
- **`zoned`** - a civil (wall-clock) date and time observed at a particular zone offset.

Arithmetic on an `instant` is exact SI-seconds (`instant + duration`), while calendar arithmetic on a `zoned` value is a separate, DST-aware operation (`zoned:add`), so the two can never be confused. Distinct from `os.time`/`os.date`, which work in raw integer epochs: bridge them with `time.instant(os.time())` and `instant:epoch()`.
