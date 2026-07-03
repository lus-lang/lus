---
name: time.weekday
module: time
kind: constant
since: 1.7.0
stability: unstable
origin: lus
type: enum
---

A first-class enum of the days of the week, following ISO 8601 numbering: `monday` = 1 through `sunday` = 7. The `weekday` field of a `zoned` returns one of these values.

```lus
local z = time.zoned{ year = 2026, month = 7, day = 2 }
assert(z.weekday == time.weekday.thursday)
print(tonumber(z.weekday))          -- 4
```
