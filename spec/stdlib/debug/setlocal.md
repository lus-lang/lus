---
name: debug.setlocal
module: debug
kind: function
since: 0.1.0
pledges: ["debug"]
stability: stable
origin: lua
params:
  - name: level
    type: integer
  - name: local_
    type: integer
  - name: value
    type: any
returns: string|nil
---

Assigns a value to a local variable at an active stack level and returns the name of the variable, or `nil` when the level has no variable at that index.

The function accepts an optional thread as its first argument, and the remaining arguments then refer to that thread.

- `level` is the stack level. Level 1 is the function that called `debug.setlocal`, level 2 its caller, and so on.
- `local_` is the index of the variable, counted as [`debug.getlocal`](/manual/api#debug.getlocal) counts it. Negative indices reach the extra arguments of a vararg function.
- `value` is the new value, of any type.

If the index names a variable, the function stores `value` and returns the name. Otherwise it changes nothing and returns `nil`. A level beyond the stack raises `bad argument #1 to 'setlocal' (level out of range)`, and a missing or non-integer `level` or `local_` raises a `bad argument` error for that argument.

The following example changes a local of the running function.

```lus
local function demo()
    local count = 1
    print(debug.setlocal(1, 1, 99))    --> count
    print(count)                       --> 99
    print(debug.setlocal(1, 5, 0))     --> nil
end
demo()
```

Unlike `debug.getlocal`, this function takes only a level, since a function that is not running has no variables to assign. [`debug.setupvalue`](/manual/api#debug.setupvalue) assigns a captured variable of a closure.
