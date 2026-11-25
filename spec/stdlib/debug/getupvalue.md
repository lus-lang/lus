---
name: debug.getupvalue
module: debug
kind: function
since: 0.1.0
pledges: ["debug"]
stability: stable
origin: lua
params:
  - name: f
    type: function
  - name: up
    type: integer
returns: string|nil
---

Returns the name and the value of an upvalue of a function, or no values when the function has no upvalue at that index.

- `f` is a Lus function or a native function.
- `up` is the index of the upvalue, starting at 1. Upvalues are numbered in the order that the function first refers to them.

On success the function returns two values: the name of the upvalue and its current value. The upvalues of a native function have the empty string as their name. An index below 1 or above the number of upvalues returns no values at all. An `f` that is not a function raises `bad argument #1 to 'getupvalue' (function expected)`, and a missing or non-integer `up` raises `bad argument #2 to 'getupvalue'`.

The following example lists the upvalues of a closure.

```lus
local count, step = 0, 5

local function bump()
    count = count + step
    return count
end

print(debug.getupvalue(bump, 1))  --> count  0
print(debug.getupvalue(bump, 2))  --> step  5
print(select("#", debug.getupvalue(bump, 3)))  --> 0
```

The number of upvalues of a function is the `nups` field of [`debug.getinfo`](/manual/api#debug.getinfo) with the `u` option. [`debug.setupvalue`](/manual/api#debug.setupvalue) changes an upvalue, and [`debug.upvalueid`](/manual/api#debug.upvalueid) tells whether two closures share one.
