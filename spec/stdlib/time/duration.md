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

Returns a `duration` whose length is the sum of the units given in a table.

- `fields` is a table with any of the integer fields `days`, `hours`, `minutes`, `seconds`, `millis`, `micros`, and `nanos`. Each field is optional, may be negative, and counts 0 when absent. A day is always 86,400 seconds. The function ignores every other key.

The function returns one `duration`. A `fields` that is not a table raises `bad argument #1 to 'duration' (table expected)`. A field without an integer value raises `bad argument #1 to 'duration' (field 'hours' has no integer representation)`, with the name of the field. A sum beyond the range of a duration raises `time value out of range`.

A duration has these methods:

- `d:seconds()` returns the length in seconds as a float.
- `d:millis()` returns the length in milliseconds as a float.
- `d:parts()` returns a table with the boolean `negative` and the integers `days`, `hours`, `minutes`, `seconds`, and `nanos`, which break down the absolute length with each field below its next larger unit.

Durations support `+`, `-`, unary `-`, and multiplication by an integer on either side, and they compare with `==`, `<`, and `<=`. Multiplying by a float without an integer value raises `bad argument #2 to 'mul' (number has no integer representation)`, and adding a number raises `bad argument #2 to 'add' (time.duration expected, got number)`. Division raises an arithmetic error. `tostring` gives the form `time.duration(5400 s + 0 ns)`.

The following example builds a duration from two units and breaks a negative one into parts.

```lus
local d = time.duration{ hours = 1, minutes = 30 }
print(d:seconds(), d:millis())  --> 5400.0  5400000.0
print(d == 3 * time.minutes(30))  --> true
local p = (-time.duration{ days = 1, seconds = 90 }):parts()
print(p.negative, p.days, p.minutes, p.seconds)  --> true  1  1  30
print(tostring(time.duration{ micros = 1500 }))  --> time.duration(0 s + 1500000 ns)
```

A key such as `weeks` is not a unit of a duration, so it contributes nothing. The single-unit constructors [`time.days`](/manual/api#time.days), [`time.hours`](/manual/api#time.hours), [`time.minutes`](/manual/api#time.minutes), [`time.seconds`](/manual/api#time.seconds), and [`time.millis`](/manual/api#time.millis) build a duration from one integer. Adding a duration to an instant moves it by exact seconds, and `zoned:add` on a [`time.zoned`](/manual/api#time.zoned) value moves it by calendar units instead.
