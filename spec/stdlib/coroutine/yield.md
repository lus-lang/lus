---
name: coroutine.yield
module: coroutine
kind: function
since: 0.1.0
stability: stable
origin: lua
vararg: true
returns: any
---

`coroutine.yield(...)` suspends the running coroutine and returns the extra arguments of the `resume` that continues it.

The arguments of `yield` become the extra results of the [`coroutine.resume`](/manual/api#coroutine.resume) that ran the coroutine, after its leading `true`. When the coroutine is resumed again, `yield` returns the extra arguments of that `resume`.

Yielding from the main thread raises `attempt to yield from outside a coroutine`. Yielding while a native function that does not support yielding is on the stack, such as the comparison function of `table.sort`, raises `attempt to yield across a C-call boundary`.

```lus
local co = coroutine.create(function()
    local reply = coroutine.yield("ping")
    print("got", reply)    --> got  pong
end)
print(coroutine.resume(co))           --> true  ping
print(coroutine.resume(co, "pong"))   --> true
```

In a coroutine given to [`coroutine.detach`](/manual/api#coroutine.detach), `yield` lets the other detached coroutines run. The runtime resumes the coroutine on its next turn, the arguments are dropped, and `yield` returns no values. [`coroutine.isyieldable`](/manual/api#coroutine.isyieldable) tells whether a yield is possible.
