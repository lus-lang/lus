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

Returns a `zone` with a fixed offset from UTC, given in seconds east of UTC.

- `seconds` is the offset, an integer from -86,400 to 86,400. A negative value lies west of UTC.

The function returns one `zone`. Its `z:name()` and `tostring` give the offset as `+HH:MM` or `-HH:MM`, and seconds below a whole minute do not appear in the name. Its `z:offset(instant)` returns `seconds` for every instant, since a fixed offset never varies. An offset outside the range raises `bad argument #1 to 'offset' (offset out of range)`, and a float without an integer value raises `bad argument #1 to 'offset' (number has no integer representation)`.

The following example renders an instant at a fixed offset of five hours west of UTC.

```lus
local est = time.offset(-5 * 3600)
print(est:name(), est:offset(time.instant(0)))    --> -05:00  -18000
print(time.instant(1782998100):at(est):iso())     --> 2026-07-02T08:15:00-05:00
print(time.offset(19800):name())                  --> +05:30
```

An integer offset passed to `instant:at` or to [`time.zoned`](/manual/api#time.zoned) has the same effect as a zone from this function. [`time.zone`](/manual/api#time.zone) returns a named zone whose offset follows daylight saving.
