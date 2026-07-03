---
name: time.month
module: time
kind: constant
since: 1.7.0
stability: unstable
origin: lus
type: enum
---

A first-class enum of the months, `january` = 1 through `december` = 12. It may be used wherever a month integer is expected (e.g. the `month` field of `time.zoned`, `zoned:with`, and `zoned:add`), taking its 1-based index. The `month` field of a `zoned` returns a plain integer, for arithmetic and parity with `os.date`.

```lus
local z = time.zoned{ year = 2026, month = time.month.july, day = 2 }
print(z.month)                      -- 7
```
