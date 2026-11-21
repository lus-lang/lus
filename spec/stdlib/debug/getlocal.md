---
name: debug.getlocal
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: f
    type: function|integer
  - name: local_
    type: integer
returns: string|nil
---

Returns the name and the value of a local variable at an active stack level, or the name of a parameter of a function.

The function accepts an optional thread as its first argument, and the remaining arguments then refer to that thread.

- `f` is an integer stack level, or a function. Level 1 is the function that called `debug.getlocal`, level 2 its caller, and so on.
- `local_` is the index of the variable. Positive indices count the locals that are active at the current point of the level, in the order of their declaration, starting with the parameters. Negative indices count the extra arguments of a vararg function, so `-1` is the first of them.

Given a level, the function returns two values: the name and the current value. An extra argument has the name `"(vararg)"`. Given a function, it returns only the name of parameter `local_`, since a function that is not running has no values. An index with no variable returns `nil`, and so does a native function.

A level beyond the stack raises `bad argument #1 to 'getlocal' (level out of range)`. A missing or non-integer `local_` raises `bad argument #2 to 'getlocal'`.

The following example reads a parameter, a local, and an extra argument of a running function, and then a parameter name of the same function from outside.

```lus
local function area(w, h, ...)
    local result = w * h
    print(debug.getlocal(1, 1))    --> w  3
    print(debug.getlocal(1, 3))    --> result  12
    print(debug.getlocal(1, -1))   --> (vararg)  extra
    print(debug.getlocal(1, 4))    --> nil
    return result
end
area(3, 4, "extra")
print(debug.getlocal(area, 2))     --> h
```

A local becomes active after the statement that declares it, so a variable whose declaration has not run yet has no index. [`debug.setlocal`](/manual/api#debug.setlocal) changes the value of a local, and [`debug.getupvalue`](/manual/api#debug.getupvalue) reads the variables that a closure captured.
