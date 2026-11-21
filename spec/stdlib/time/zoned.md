---
name: time.zoned
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
params:
  - name: fields
    type: table
  - name: zone
    type: zone|integer
    optional: true
returns: zoned
---

Returns a `zoned` value, a civil date and time read from a table of wall-clock fields in a zone.

- `fields` is a table with any of the integer fields `year`, `month`, `day`, `hour`, `minute`, `second`, and `nanosecond`. Missing fields take their values from 1970-01-01T00:00:00. The `month` field also accepts a [`time.month`](/manual/api#time.month) member, which stands for its position.
- `zone` chooses how the fields are read. A zone from [`time.zone`](/manual/api#time.zone), [`time.offset`](/manual/api#time.offset), or [`time.localzone`](/manual/api#time.localzone) resolves them with the offset that the zone observes at that wall-clock time. An integer is a fixed offset in seconds east of UTC, from -86,400 to 86,400. An absent `zone` means UTC.

The function returns one `zoned` value. A month outside 1 to 12 raises `bad argument #1 to 'zoned' (month out of range)`, and a day outside 1 to 31 raises `bad argument #1 to 'zoned' (day out of range)`. Within those limits, a field beyond its range carries into the next larger field, so day 30 of February is the 2nd of March and hour 25 is 1 o'clock the next day. A field without an integer value raises `bad argument #1 to 'zoned' (field 'hour' has no integer representation)`, with the name of the field. A `fields` that is not a table raises `bad argument #1 to 'zoned' (table expected)`. An integer offset outside its range raises `bad argument #2 to 'zoned' (offset out of range)`, and a `zone` that is neither a zone nor an integer raises `bad argument #2 to 'zoned' (number expected)`.

A zoned value has the read-only fields `year`, `month`, `day`, `hour`, `minute`, `second`, `nanosecond`, `yearday`, and `offset`, all integers, and `weekday`, a [`time.weekday`](/manual/api#time.weekday) member. `month` runs from 1 to 12, and `offset` is in seconds east of UTC. It has these methods:

- `z:instant()` returns the instant that the value denotes.
- `z:iso()` returns the ISO 8601 form with the offset, which is `Z` for an offset of zero. `tostring(z)` returns the same text.
- `z:format(fmt)` formats the fields with the `strftime` specifiers of [`os.date`](/manual/api#os.date). `%Z` gives the abbreviation of a named zone and the empty string for a fixed offset.
- `z:with(fields)` returns a copy with the named fields replaced, read as `time.zoned` reads them.
- `z:add(amounts)` returns a copy moved by the integer calendar amounts `years`, `months`, `weeks`, `days`, `hours`, `minutes`, `seconds`, and `nanos`, each of which may be negative.

Both `with` and `add` work on the wall clock and resolve the offset of the result through the zone of the original. `z:add{ days = 1 }` keeps the wall-clock time on the next day across a daylight saving transition, and so does `z:add{ hours = 24 }`. Adding months or years keeps the day when it exists and otherwise clamps it to the last day of the target month, so January 31 plus one month is February 28 or 29. To move by exact elapsed time, add a duration to `z:instant()`.

The following example builds a civil time in New York, reads its fields, and moves it by a calendar month.

```lus
local ny = time.zone("America/New_York")
local z = time.zoned({ year = 2026, month = 7, day = 2, hour = 9, minute = 15 }, ny)
print(z:iso(), z.offset)                     --> 2026-07-02T09:15:00-04:00  -14400
print(z:instant():iso(), z.yearday)          --> 2026-07-02T13:15:00Z  183
print(tonumber(z.weekday), z:format("%A"))   --> 4  Thursday
print(z:add{ months = 1 }:iso())             --> 2026-08-02T09:15:00-04:00
print(z:with{ hour = 23 }:iso())             --> 2026-07-02T23:15:00-04:00
```

A wall-clock time that a zone skips at the start of daylight saving moves forward by the length of the skip, so 02:30 on a day when New York jumps from 02:00 to 03:00 becomes 03:30 with the offset `-04:00`. A wall-clock time that a zone repeats at the end of daylight saving takes the earlier of its two instants, the one with the daylight saving offset. Two zoned values are equal only when they are the same object, and comparing them with `<` raises `attempt to compare two time.zoned values`, so a program compares their instants. Assigning to a field raises an error, and reading a field that does not exist returns `nil`. `instant:at(zone)` returns the zoned value that a zone observes at an instant.
