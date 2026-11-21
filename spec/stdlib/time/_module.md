---
name: time
module: time
kind: module
since: 1.7.0
stability: unstable
origin: lus
---

The `time` module handles dates, times, and spans of time with three immutable value types, and it resolves time zones from an IANA database compiled into the runtime.

- An _instant_ is an absolute point on the UTC timeline, with nanosecond precision. [`time.now`](/manual/api#time.now), [`time.instant`](/manual/api#time.instant), and [`time.parse`](/manual/api#time.parse) return instants.
- A _duration_ is a signed span of time, with nanosecond precision. [`time.duration`](/manual/api#time.duration) and the single-unit constructors such as [`time.hours`](/manual/api#time.hours) return durations.
- A _zoned_ value is a civil date and time, the reading of a wall clock, observed in a zone. [`time.zoned`](/manual/api#time.zoned) and `instant:at(zone)` return zoned values.

Adding a duration to an instant is exact arithmetic in SI seconds. Calendar arithmetic, such as the same wall-clock time on the next day, is the separate method `zoned:add`, which follows the daylight saving rules of the zone. The type of a value therefore says which kind of arithmetic applies.

The following example moves an instant by exact hours and renders it in a named zone.

```lus
local i = time.instant(1782998100)
print(i:iso())                                    --> 2026-07-02T13:15:00Z
print((i + time.hours(72)):iso())                 --> 2026-07-05T13:15:00Z
print(i:at(time.zone("America/New_York")):iso())  --> 2026-07-02T09:15:00-04:00
```

The module works alongside [`os.time`](/manual/api#os.time) and [`os.date`](/manual/api#os.date), which use integer Unix seconds. `time.instant(os.time())` turns such an epoch into an instant, and `instant:epoch()` turns an instant back into one. Time values are userdata, so a worker message cannot carry them and `tojson` writes them as `null`. The [time](/manual/time) page of the manual describes the module in full.
