---
name: time.month
module: time
kind: constant
since: 1.7.0
stability: unstable
origin: lus
type: enum
---

An enum of the months of the year, from `january`, at position 1, to `december`, at position 12.

The members are `january`, `february`, `march`, `april`, `may`, `june`, `july`, `august`, `september`, `october`, `november`, and `december`. [`tonumber`](/manual/api#tonumber) returns the position of a member, and `time.month[n]` returns the member at position `n`, or `nil` outside 1 to 12. A member may be passed wherever a month is expected, such as the `month` field of [`time.zoned`](/manual/api#time.zoned) and of `zoned:with`, and it stands for its position there.

The following example builds a date with a member and reads the month back as an integer.

```lus
local z = time.zoned{ year = 2026, month = time.month.july, day = 2 }
print(z.month, tonumber(time.month.july))  --> 7  7
print(time.month[12] == time.month.december)  --> true
print(type(time.month.july), time.month.smarch)  --> enum  nil
```

The `month` field of a zoned value is a plain integer from 1 to 12, so that arithmetic on it works as on any integer. Members follow the rules of every [enum](/manual/guide#enums): they compare in order with `<`, and arithmetic on them raises an error. The value `time.month` is itself the member `january`, since an enum evaluates to its first member. [`time.weekday`](/manual/api#time.weekday) is the enum of the days of the week.
