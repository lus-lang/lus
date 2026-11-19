---
name: time.zoned
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
params:
  - name: fields
    type: table
  - name: zone
    type: zone|integer
    optional: true
returns: zoned
---

Constructs a `zoned` civil datetime from a table of `fields` (`year`, `month`, `day`, `hour`, `minute`, `second`, `nanosecond`). Missing fields default to the start of 1970-01-01. The second argument selects how the wall-clock fields are interpreted: pass a `zone` (from `time.zone`, `time.offset`, or `time.localzone`) for a DST-aware resolution, an integer for a fixed offset east of UTC, or omit it for UTC.

A `zoned` exposes read-only fields `year`, `month`, `day`, `hour`, `minute`, `second`, `nanosecond`, `weekday`, `yearday`, and `offset`, plus the methods `z:instant()`, `z:format(fmt)`, and `z:iso()`. `month` is an integer (1-12). `weekday` is a [`time.weekday`](/manual/api#time.weekday) enum value (`monday` through `sunday`).

Two methods derive new values:

- `z:with{...}` returns a copy with the named civil fields replaced.
- `z:add{...}` returns a copy advanced by calendar amounts (`years`, `months`, `weeks`, `days`, `hours`, `minutes`, `seconds`, `nanos`, negative allowed).

Both operate on the wall clock and re-resolve the offset through the originating zone. `z:add{days = 1}` keeps the same wall-clock time the next day even across a DST transition, and adding months clamps the day to the target month's length (Jan 31 plus one month is Feb 28 or 29).

The following example builds a fixed-offset civil time and reads it back.

```lus
local z = time.zoned({ year = 2026, month = 7, day = 2, hour = 9 }, -4 * 3600)
print(z:iso())          -- "2026-07-02T09:00:00-04:00"
print(z.weekday)        -- 4  (Thursday)
```
