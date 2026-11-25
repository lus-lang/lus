---
name: debug.getcontext
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
returns: string|nil
---

Returns the name, the value, and the place of declaration of context variable number `n` as the coroutine `co` sees it, or `nil` past the last variable.

- `co` is a coroutine, and the running coroutine when it is left out.
- `n` is the number of the variable, starting at 1. The live context variables of the state are numbered in the order in which their declarations ran. A variable that nothing refers to any more leaves the numbering when the collector reclaims it, so the numbers of the variables declared after it move down by one.

The value is the one that `co` assigned, or the one it inherited from the coroutine that created it, or the default of the variable. The place is a string `"SOURCE:LINE"` that names the chunk and the line of the declaration, which tells two variables of the same name apart. A context variable is a local declared with the `<context>` attribute ([Values for each coroutine](/manual/guide#values-for-each-coroutine)).

The following example reads a variable as the main coroutine and as another coroutine see it.

```lus
local function find(name)
    local n = 1
    while true do
        local found = debug.getcontext(n)
        if found == nil or found == name then return n end
        n = n + 1
    end
end

local user <context> = "nobody"
local co = coroutine.create(function()
    user = "ada"
    coroutine.yield()
end)
coroutine.resume(co)
local n = find("user")
print((select(2, debug.getcontext(n))))       --> nobody
print((select(2, debug.getcontext(co, n))))   --> ada
```

[`debug.setcontext`](/manual/api#debug.setcontext) assigns a value for a coroutine.
