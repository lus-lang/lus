---
name: assert
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: v
    type: any
  - name: message
    type: any
    optional: true
returns: any
---

`assert(v, message, ...)` returns all of its arguments when `v` is truthy and raises an error when `v` is falsy.

The parameter `v` is the value to check. The optional `message` is the error object to raise when `v` is falsy, and it defaults to `"assertion failed!"`. Any further arguments pass through on success.

On success, `assert` returns `v`, `message`, and every further argument, unchanged. On failure it raises an error. A string message, including the default one, is prefixed with the position of the `assert` call, as in `script.lus:3: assertion failed!`. A message of any other type is raised unchanged, and a `nil` message raises the string `"<no error object>"`. A call with no arguments raises `bad argument #1 to 'assert' (value expected)`.

```lus
local n = assert(tonumber("42"), "not a number")
print(n)                     --> 42

local ok, err = catch assert(tonumber("x"), { code = 400 })
print(ok, err.code)          --> false  400
```

A function that fails by returning `nil` and a message fits `assert` directly, so `assert(io.open(path))` raises the message of `io.open`. [`error`](/manual/api#error) raises an error unconditionally, and the `catch` expression captures one, as [Error handling](/manual/guide#errors) describes.
