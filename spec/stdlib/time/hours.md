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

Returns a `duration` of `n` hours, the same value as `time.duration{ hours = n }`.

- `n` is the number of hours, an integer. It may be zero or negative. A float with an exact integer value and a string that converts to one are accepted.

The function returns one `duration`. A float without an integer value raises `bad argument #1 to 'time.hours' (number has no integer representation)`, and a missing `n` raises `bad argument #1 to 'time.hours' (number expected, got no value)`. A result beyond the range of a duration raises `time value out of range`.

The following example builds a duration, compares it with an equal one, and adds it to an instant.

```lus
local d = time.hours(5)
print(d:seconds())  --> 18000.0
print(d == time.duration{ minutes = 300 })  --> true
print((time.instant(0) + d):iso())  --> 1970-01-01T05:00:00Z
```

[`time.duration`](/manual/api#time.duration) combines several units and lists the methods and operators of a duration. The other single-unit constructors are [`time.days`](/manual/api#time.days), [`time.minutes`](/manual/api#time.minutes), [`time.seconds`](/manual/api#time.seconds), and [`time.millis`](/manual/api#time.millis).
