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

Returns a `duration` of `n` days of 86,400 seconds each, the same value as `time.duration{ days = n }`.

- `n` is the number of days, an integer. It may be zero or negative. A float with an exact integer value and a string that converts to one are accepted.

The function returns one `duration`. A float without an integer value raises `bad argument #1 to 'time.days' (number has no integer representation)`, and a missing `n` raises `bad argument #1 to 'time.days' (number expected, got no value)`. A result beyond the range of a duration raises `time value out of range`.

The following example builds a duration, compares it with an equal one, and adds it to an instant.

```lus
local d = time.days(2)
print(d:seconds())                                   --> 172800.0
print(d == time.duration{ hours = 48 })              --> true
print((time.instant(0) + d):iso())                   --> 1970-01-03T00:00:00Z
```

A day is always 86,400 seconds, so adding days to an instant ignores daylight saving, while `z:add{ days = n }` on a [`time.zoned`](/manual/api#time.zoned) value keeps the wall-clock time. [`time.duration`](/manual/api#time.duration) combines several units and lists the methods and operators of a duration. The other single-unit constructors are [`time.hours`](/manual/api#time.hours), [`time.minutes`](/manual/api#time.minutes), [`time.seconds`](/manual/api#time.seconds), and [`time.millis`](/manual/api#time.millis).
