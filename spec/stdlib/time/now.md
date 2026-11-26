---
name: time.now
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
returns: instant
---

Returns an `instant` for the current time, read from the wall clock of the system.

The function takes no arguments and raises no errors. The instant has nanosecond resolution where the system clock provides it. The wall clock may jump when the system time changes, so two readings may compare out of order.

The following example reads the current time. The exact value differs on every run, so the example prints properties that hold for any reading.

```lus
local n = time.now()
print(math.type(n:epoch()), n:nanos() < 1000000000)  --> integer  true
print(time.instant(0) < n)  --> true
print(n:iso():match("^%d%d%d%d%-%d%d%-%d%dT") ~= nil)  --> true
```

[`time.monotonic`](/manual/api#time.monotonic) measures elapsed time with a clock that never moves backwards. `time.now():epoch()` returns the current time as integer Unix seconds.
