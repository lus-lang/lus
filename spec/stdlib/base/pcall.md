---
name: pcall
module: base
kind: function
since: 0.1.0
stability: removed
origin: lua
params:
  - name: f
    type: function
vararg: true
---

`pcall` is a Lua function that Lus removed, so the global `pcall` is `nil`. The `catch` expression takes its place: `catch f(...)` returns `true` and every result of the call on success, and `false` and the error object on failure.

```lus
local function divide(a, b)
    if b == 0 then
        error("division by zero", 0)
    end

    return a / b
end

print(catch divide(1, 2))  --> true  0.5
print(catch divide(1, 0))  --> false  division by zero
print(pcall)  --> nil
```

[Error handling](/manual/guide#errors) describes `catch` and its handlers.
