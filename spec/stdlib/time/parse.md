---
name: time.parse
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
params:
  - name: s
    type: string
  - name: format
    type: string
    optional: true
returns: instant|zoned
---

Parses a date and time from text and returns an `instant`, or a `zoned` value when the text carries a numeric offset.

- `s` is the text to parse.
- `format` is an optional pattern. Without it, `s` is read as ISO 8601.

The result is a [`time.zoned`](/manual/api#time.zoned) value when the text carries an explicit numeric offset such as `-04:00` or `-0400`, in the zone of that fixed offset. It is an instant when the text is in UTC, written with `Z`, or carries no offset, which reads as UTC.

Without `format`, the text is a date `YYYY-MM-DD` alone, which means midnight UTC, or a date and a time `HH:MM` separated by `T` or a space. Seconds `:SS` are optional, and a fraction after `.` or `,` keeps up to nine digits, to the nanosecond. An offset `Z`, `+HH:MM`, `+HHMM`, or `+HH` may follow. A month outside 1 to 12 or a day outside 1 to 31 raises `ISO 8601 date out of range in '...'`, quoting the text. Other malformed text raises an error that quotes it, such as `invalid ISO 8601 date in '...'`, `invalid ISO 8601 time in '...'`, `invalid fractional seconds in '...'`, or `trailing characters in '...'`. A day beyond the length of its month, or an hour of 24 or more, carries into the next month or day.

With `format`, the text must match a pattern built from these specifiers:

- `%Y` reads a year of one to four digits, and `%y` reads one or two digits and adds 2000, giving a year from 2000 to 2099.
- `%m`, `%d`, `%H`, `%M`, and `%S` read one or two digits of the month, day, hour, minute, and second. `%e` is the same as `%d`, and both skip leading spaces.
- `%z` reads `Z`, or an offset `+HH`, `+HHMM`, or `+HH:MM` with either sign.
- `%%` reads a literal `%`.

A space in the pattern matches a run of spaces and tabs, and every other character matches itself. Fields that the pattern leaves out take their values from 1970-01-01T00:00:00. Text that does not match raises `'...' does not match time format '...'`, quoting the text and the pattern, and any other specifier raises `unsupported time format specifier`. Parsing is the same on every platform.

The following example parses ISO 8601 text with and without an offset, then text in a custom pattern.

```lus
local i = time.parse("2026-07-02 13:15")
print(i:iso())                                  --> 2026-07-02T13:15:00Z
local z = time.parse("2026-07-02T09:15:00-04:00")
print(z.offset, z:instant() == i)               --> -14400  true
local p = time.parse("02/07/2026 09:15 -0400", "%d/%m/%Y %H:%M %z")
print(p:iso())                                  --> 2026-07-02T09:15:00-04:00
print(catch time.parse("2026-13-01"))           --> false  ...: ISO 8601 date out of range in '2026-13-01'
```

With a `format`, the pattern must account for the whole text, so `time.parse("2026-07-02x", "%Y-%m-%d")` raises `trailing characters in '2026-07-02x'`. A `%z` that reads `Z` returns an instant. `instant:iso()` and `zoned:iso()` write the ISO 8601 form that this function reads.
