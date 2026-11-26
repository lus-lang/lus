---
name: os.date
module: os
kind: function
since: 0.1.0
stability: deprecated
deprecated_by: "time.instant"
origin: lua
params:
  - name: format
    type: string
    optional: true
  - name: time
    type: integer
    optional: true
returns: string|table
---

`os.date` is deprecated. [`time.instant`](/manual/api#time.instant)`(t)` turns seconds into an instant, whose `format` method writes the same `strftime` patterns and whose `at` method gives the date fields in a zone.

Formats a time as a string, or breaks it into a table of date fields, and returns the result.

`format` is a string that defaults to `"%c"`. A leading `"!"` formats the time in UTC, and without it the time is formatted in the local time zone, which comes from the `TZ` environment variable and then the system zone database. The rest of `format` is either `"*t"` or a `strftime` pattern in the "C" locale. `time` is an integer count of seconds since the epoch, as [`os.time`](/manual/api#os.time) returns, and defaults to the current time.

With `"*t"`, the call returns a table with the integer fields `year`, `month`, `day`, `hour`, `min`, `sec`, `wday` (1 is Sunday), and `yday` (1 is January 1), and the boolean field `isdst`. Any other format returns a string in which each conversion specifier such as `%Y` or `%H` is replaced by its value. An unknown specifier raises `bad argument #1 to 'date' (invalid conversion specifier '%Q')`, and a `time` with a fraction raises `bad argument #2 to 'date' (number has no integer representation)`. The function requires no permission.

```lus
print(os.date("!%Y-%m-%d %H:%M:%S", 0))  --> 1970-01-01 00:00:00
print(os.date("!%A, %B %d", 86400))  --> Friday, January 02
local t = os.date("!*t", 86400)
print(t.year, t.month, t.day, t.wday)  --> 1970  1  2  6
```

The `time` library offers time zones, durations, and parsing beyond these formats. [`os.time`](/manual/api#os.time) turns a table of fields back into a time.
