---
name: os.difftime
module: os
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: t2
    type: integer
  - name: t1
    type: integer
returns: number
---

Returns the number of seconds from `t1` to `t2` as a float.

`t2` and `t1` are integer times in seconds since the epoch, as [`os.time`](/manual/api#os.time) returns, and both are required. The result is `t2 - t1` converted to a float, so it is negative when `t2` is earlier. A missing argument raises a `bad argument` error, and so does a number with a fraction. The function requires no permission.

```lus
local t1 = os.time({ year = 2000, month = 1, day = 1, hour = 0 })
local t2 = os.time({ year = 2000, month = 1, day = 1, hour = 6 })
print(os.difftime(t2, t1))  --> 21600.0
print(os.difftime(t1, t2))  --> -21600.0
```

[`os.clock`](/manual/api#os.clock) measures processor time with a fraction of a second.
