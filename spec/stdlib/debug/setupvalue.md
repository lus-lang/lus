---
name: debug.setupvalue
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
  - name: value
    type: any
returns: string|nil
---

Assigns a value to an upvalue of a function and returns the name of the upvalue, or returns no values when the function has no upvalue at that index.

- `f` is a Lus function or a native function.
- `up` is the index of the upvalue, starting at 1, numbered as [`debug.getupvalue`](/manual/api#debug.getupvalue) numbers it.
- `value` is the new value, of any type.

If the index names an upvalue, the function stores `value` and returns the name, which is the empty string for an upvalue of a native function. Otherwise it changes nothing and returns no values at all. An `f` that is not a function raises `bad argument #1 to 'setupvalue' (function expected)`, and a missing `value` raises `bad argument #3 to 'setupvalue' (value expected)`, so storing `nil` takes an explicit `nil`.

The following example changes a variable that a closure captured. The local in the enclosing scope is the same variable, so it changes too.

```lus
local step = 5

local function bump(n)
    return n + step
end

print(debug.setupvalue(bump, 1, 100))  --> step
print(bump(1), step)  --> 101  100
print(select("#", debug.setupvalue(bump, 2, 0)))  --> 0
```

Every closure that shares the upvalue sees the new value. [`debug.upvaluejoin`](/manual/api#debug.upvaluejoin) makes two closures share one upvalue.
