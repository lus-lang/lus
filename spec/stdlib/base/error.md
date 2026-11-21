---
name: error
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: message
    type: any
  - name: level
    type: integer
    optional: true
---

`error(message, level)` raises an error with `message` as the error object and never returns.

The parameter `message` is the error object and may be any value. The optional `level` says which function the position in a string message points to, and defaults to `1`.

- Level `1` points to the function that called `error`.
- Level `2` points to the caller of that function, and each higher level goes one call further out.
- Level `0` adds no position.

When `message` is a string and `level` is positive, `error` prefixes it with the chunk name and line of the chosen function, as in `script.lus:4: bad input`. A message of any other type is raised unchanged. A `nil` message, or a call with no arguments, raises the string `"<no error object>"`.

```lus
local function parse(s)
    return tonumber(s) or error("not a number: " .. s, 0)
end

print(catch parse("12"))          --> true  12
print(catch parse("x"))           --> false  not a number: x
print(select(2, catch error({ code = 7 })).code)   --> 7
```

The `catch` expression captures the error object, as [Error handling](/manual/guide#errors) describes. [`assert`](/manual/api#assert) raises an error when a value is falsy.
