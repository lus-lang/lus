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

Parses a date/time string `s`. Returns a `zoned` when the input carries an explicit numeric offset (e.g. `-04:00` or `-0400`), or an `instant` when it is in UTC (`Z`) or offset-free (assumed UTC).

Without a `format`, `s` is read as ISO 8601: a date alone (`2026-07-02`, midnight UTC), a date and time separated by `T` or a space, optional seconds, and fractional seconds to nanosecond precision.

With a `format`, `s` is matched against an explicit pattern using the specifiers `%Y` `%y` `%m` `%d` `%e` `%H` `%M` `%S` `%z` and `%%`. A space in the pattern matches a run of whitespace; any other literal must match exactly. Parsing is portable and does not depend on the platform's `strptime`.

```lus
local i = time.parse("2026-07-02T13:15:00Z")            -- ISO -> instant
local z = time.parse("02/07/2026 09:15 -0400",
                     "%d/%m/%Y %H:%M %z")               -- pattern -> zoned
```
