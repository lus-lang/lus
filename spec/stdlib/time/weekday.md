---
name: time.weekday
module: time
kind: constant
since: 1.7.0
stability: unstable
origin: lus
type: enum
---

An enum of the days of the week with ISO 8601 numbering, from `monday`, at position 1, to `sunday`, at position 7.

The members are `monday`, `tuesday`, `wednesday`, `thursday`, `friday`, `saturday`, and `sunday`. [`tonumber`](/manual/api#tonumber) returns the position of a member, and `time.weekday[n]` returns the member at position `n`, or `nil` outside 1 to 7. The `weekday` field of a [`time.zoned`](/manual/api#time.zoned) value is one of these members.

The following example reads the day of the week of a date.

```lus
local z = time.zoned{ year = 2026, month = 7, day = 2 }
print(z.weekday == time.weekday.thursday)       --> true
print(tonumber(z.weekday))                      --> 4
print(time.weekday[7] == time.weekday.sunday)   --> true
```

`print` shows a member as `enum:` and an address, so a program prints `tonumber(member)` or a name from `z:format("%A")`. Members follow the rules of every [enum](/manual/guide#enums): they compare in order with `<`, and arithmetic on them raises an error. The value `time.weekday` is itself the member `monday`. [`time.month`](/manual/api#time.month) is the enum of the months.
