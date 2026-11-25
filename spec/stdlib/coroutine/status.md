---
name: coroutine.status
module: coroutine
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: co
    type: thread
returns: string
---

`coroutine.status(co)` returns the status of the coroutine `co` as one of the strings `"running"`, `"suspended"`, `"normal"`, and `"dead"`.

The parameter `co` must be a coroutine, and any other value raises `bad argument #1 to 'status' (thread expected, got TYPE)`. The statuses mean these:

- `"running"` is the coroutine that calls `status`.
- `"suspended"` is a coroutine that has not started yet or that yielded.
- `"normal"` is a coroutine that is active but not running, because it resumed another coroutine.
- `"dead"` is a coroutine whose body returned, raised an error, or was closed.

```lus
local co

co = coroutine.create(function()
    local inner = coroutine.create(function()
        return coroutine.status(co)
    end)

    print(coroutine.status(co), coroutine.resume(inner))  --> running  true  normal
    coroutine.yield()
end)

print(coroutine.status(co))  --> suspended
coroutine.resume(co)
coroutine.resume(co)
print(coroutine.status(co))  --> dead
```

A coroutine given to [`coroutine.detach`](/manual/api#coroutine.detach) reports `"suspended"` while it waits for its turn, for a socket, or for another coroutine, and `"dead"` once it has ended.
