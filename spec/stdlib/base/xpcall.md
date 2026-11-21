---
name: xpcall
module: base
kind: function
since: 0.1.0
stability: removed
origin: lua
params:
  - name: f
    type: function
  - name: msgh
    type: function
vararg: true
---

`xpcall` is a Lua function that Lus removed, so the global `xpcall` is `nil`. The `catch` expression with a handler takes its place: `catch[handler] f(...)` returns `true` and every result of the call on success, and `false` and the first result of `handler` on failure.

The handler receives the error object and runs after the stack has unwound to the `catch`. It can transform the error object, and it cannot inspect the frames that raised the error. A string error object still carries the position where `error` raised it. A traceback taken inside the handler, as with `catch[debug.traceback]`, starts at the line of the `catch`.

```lus
local function check(n)
    if n < 0 then error("negative input", 0) end
    return n
end

local ok, err = catch[function(e) return { message = e } end] check(-1)
print(ok, err.message)    --> false  negative input
print(xpcall)             --> nil
```

[Catch handlers](/manual/guide#catch-handlers) describes how a handler runs.
