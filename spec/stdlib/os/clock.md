---
name: os.clock
module: os
kind: function
since: 0.1.0
stability: stable
origin: lua
returns: number
---

Returns the processor time that the process has used so far, in seconds, as a float.

The function takes no arguments and requires no permission. The value counts the CPU time of every thread of the process, so it grows faster than the wall clock while workers run in parallel and slower while the program waits. Only differences between two readings are meaningful.

```lus
local start = os.clock()
local sum = 0

for i = 1, 1000000 do
    sum = sum + i
end

local used = os.clock() - start
print(math.type(used), used >= 0)  --> float  true
```

[`time.now`](/manual/api#time.now) reads the wall clock.
