---
name: time.monotonic
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
returns: instant
---

Returns an `instant` read from a monotonic clock, for measuring elapsed time.

The function takes no arguments. A monotonic reading never moves backwards and ignores changes to the wall clock, such as NTP corrections or a user setting the time. It has no calendar meaning, so it serves only to measure the time between two readings.

Subtracting two monotonic readings returns a `duration`, and adding or subtracting a duration returns another monotonic reading. Formatting a reading, calling `:iso()`, `:epoch()`, or `:at()` on it raises `monotonic instants have no calendar representation`. Subtracting a wall-clock instant from a monotonic reading, or the reverse, raises `cannot subtract instants from different clocks`.

The following example measures the time that a piece of work takes.

```lus
local start = time.monotonic()
local text = string.rep("x", 100000)
local elapsed = time.monotonic() - start
print(elapsed:seconds() >= 0, #text)  --> true  100000
print(catch start:iso())  --> false  ...: monotonic instants have no calendar representation
```

The comparison operators accept a monotonic reading and a wall-clock instant together without an error, and the result carries no meaning. `tostring` of a reading gives a form such as `time.instant(monotonic 330538 s + 741193500 ns)`. [`time.now`](/manual/api#time.now) reads the wall clock.
