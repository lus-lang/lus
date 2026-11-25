---
name: time.instant
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
params:
  - name: epoch_seconds
    type: integer
  - name: nanos
    type: integer
    optional: true
returns: instant
---

Returns an `instant` for a count of Unix seconds since 1970-01-01 UTC and an optional nanosecond fraction.

- `epoch_seconds` is the number of seconds since 1970-01-01T00:00:00Z, an integer that may be negative.
- `nanos` is the nanosecond fraction, an integer that defaults to 0. A value outside 0 to 999,999,999 carries into the seconds, so `time.instant(1, -1)` is one nanosecond before the second 1.

The function returns one `instant`. Each argument must be an integer, or a float or string with an exact integer value. A float without an integer value raises `bad argument #1 to 'time.instant' (number has no integer representation)`, and a missing or non-numeric argument raises `bad argument #1 to 'time.instant' (number expected)`. The same errors name argument 2 for `nanos`.

An instant has these methods:

- `i:epoch()` returns the integer Unix seconds, and `i:nanos()` the nanosecond fraction.
- `i:iso()` returns the ISO 8601 form in UTC, to the second. `tostring(i)` returns the same text.
- `i:format(fmt)` formats the instant in UTC with the `strftime` specifiers of [`os.date`](/manual/api#os.date).
- `i:at(zone)` returns the [`time.zoned`](/manual/api#time.zoned) value that a zone observes at the instant. The argument is a zone or an integer offset in seconds east of UTC.

Instants support `i + d` and `i - d` with a duration `d`, and `i - j` between instants, which returns a duration. They compare with `==`, `<`, and `<=`. Adding a number or another instant raises `bad argument #2 to 'add' (time.duration expected)`.

The following example builds an instant with a fraction, renders it, and moves it by a day.

```lus
local i = time.instant(1782998100, 250000000)
print(i:iso(), i:epoch(), i:nanos())  --> 2026-07-02T13:15:00Z  1782998100  250000000
print(i:at(time.zone("America/New_York")):iso())  --> 2026-07-02T09:15:00-04:00
print((i + time.days(1)):iso())  --> 2026-07-03T13:15:00Z
print(time.instant(1, -1):nanos())  --> 999999999
```

`time.instant(os.time())` turns an epoch from [`os.time`](/manual/api#os.time) into an instant. A year after 9999 prints with more than four digits, and a year before 1 prints as `0000` or a negative number. [`time.now`](/manual/api#time.now) returns the current instant, and [`time.parse`](/manual/api#time.parse) reads one from text.
