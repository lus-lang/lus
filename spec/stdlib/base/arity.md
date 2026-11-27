---
name: arity
module: base
kind: function
since: 2.0.0
stability: stable
origin: lus
params:
  - name: f
    type: function
returns: integer|nil, boolean
---

`arity(f)` returns the number of parameters that the function `f` declares, and whether `f` takes extra arguments.

`f` is the function to describe. For a function written in Lus the first result is the count of its named parameters, and the second is `true` when its parameter list ends in `...`. A method counts `self`, so a function declared as `function t:m(a)` has two parameters. For a function of the runtime or of a host program, whose parameters the runtime cannot read, the call returns `nil`. Any other value raises `bad argument #1 to 'arity' (function expected)`.

The result tells what a function is and nothing of the values it holds, so the call needs no permission. A library uses it to decide what to pass to a callback, such as a second argument only to a handler that declares one.

```lus
local function pair(_a, _b)
end

local function open(_first, ...)
    return ...
end

print(arity(pair))  --> 2  false
print(arity(open))  --> 1  true
print(arity(print))  --> nil
```

[`debug.getinfo`](/manual/api#debug.getinfo) reports more about a function and needs the `debug` permission.
