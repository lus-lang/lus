---
name: debug.setcontext
module: debug
kind: function
since: 2.0.0
pledges: ["debug"]
stability: unstable
origin: lus
params:
  - name: co
    type: thread
    optional: true
  - name: n
    type: integer
  - name: value
    type: any
returns: string|nil
---

Assigns `value` to context variable number `n` for the coroutine `co` and returns the name of the variable, or `nil` past the last variable.

`co` is a coroutine, and the running coroutine when it is left out. `n` numbers the variables as [`debug.getcontext`](/manual/api#debug.getcontext) does. The assignment changes the value that `co` sees and nothing else, exactly as an assignment inside `co` would. A coroutine that `co` creates afterwards starts with the new value. A missing `value` raises a bad argument error.

The following example gives a suspended coroutine a value before it continues.

```lus
local function find(name)
    local n = 1

    while debug.getcontext(n) ~= name do
        n = n + 1
    end

    return n
end

local trace <context> = "off"

local co = coroutine.create(function()
    coroutine.yield()
    return trace
end)

coroutine.resume(co)
print(debug.setcontext(co, find("trace"), "on"))  --> trace
print(select(2, coroutine.resume(co)))  --> on
print(trace)  --> off
```
