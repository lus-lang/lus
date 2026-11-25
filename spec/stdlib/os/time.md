---
name: os.time
module: os
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: t
    type: table
    optional: true
returns: integer
---

Returns the current time, or the time that a table of date fields describes, as an integer count of seconds since the epoch.

`t` is an optional table. Without it, the call returns the current time. With it, the call reads the integer fields `year`, `month`, and `day`, which are required, and `hour`, `min`, and `sec`, which default to 12, 0, and 0, and it interprets them in the local time zone. The boolean field `isdst` is optional.

Fields out of their usual range are normalized, so month 13 of 2000 is January 2001, and the call writes the normalized values back into `t`, together with `wday`, `yday`, and `isdst`. A missing required field raises `"field 'month' missing in date table"`, and a field that is not an integer raises `"field 'month' is not an integer"`. The function requires no permission.

```lus
local t = { year = 2000, month = 13, day = 1, hour = 0 }
local seconds = os.time(t)
print(math.type(seconds))  --> integer
print(t.year, t.month)  --> 2001  1
print(os.time(t) == seconds)  --> true
```

[`os.date`](/manual/api#os.date) breaks a time back into fields or formats it, and [`os.difftime`](/manual/api#os.difftime) subtracts two times.
