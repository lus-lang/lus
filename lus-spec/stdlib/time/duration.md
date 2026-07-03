---
name: time.duration
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
params:
  - name: fields
    type: table
returns: duration
---

Constructs a `duration` from a table summing any of `days`, `hours`, `minutes`, `seconds`, `millis`, `micros`, `nanos` (each optional, may be negative).

A `duration` supports `d:seconds()`, `d:millis()`, `d:parts()` (a normalized `{negative, days, hours, minutes, seconds, nanos}` breakdown), the operators `+`, `-`, unary `-`, and `duration * integer`, and the comparisons `==`, `<`, `<=`. See also the scalar helpers `time.days`, `time.hours`, `time.minutes`, `time.seconds`, `time.millis`.
