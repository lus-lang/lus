---
name: coroutine.close
module: coroutine
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: co
    type: thread
    optional: true
returns: boolean
---

`coroutine.close(co)` closes the coroutine `co`, putting it in the dead state, and returns `true` on success or `false` and an error object on failure.

The parameter `co` is a suspended or dead coroutine. Closing it closes its pending to-be-closed variables, those declared with the `<close>` attribute. Without `co`, `coroutine.close()` closes the running coroutine.

The results are these:

- A coroutine that closed cleanly returns `true`.
- A coroutine that had stopped with an error returns `false` and its error object the first time it is closed, and `true` after that.
- A `__close` handler that raises an error makes the result `false` and that error object.

Closing the running coroutine runs its pending to-be-closed variables and ends it as if its body had returned no values, so the `resume` that started it returns `true`. Closing the main thread raises `cannot close main thread`, and closing a coroutine that is running or normal raises `cannot close a running coroutine` or `cannot close a normal coroutine`.

```lus
local co = coroutine.create(function()
    local res <close> = setmetatable({}, { __close = function() print("released") end })
    coroutine.yield()
end)
coroutine.resume(co)
print(coroutine.close(co))    --> released
                              --> true
print(coroutine.status(co))   --> dead
```

Closing a coroutine given to [`coroutine.detach`](/manual/api#coroutine.detach) cancels it. The runtime stops resuming it, its pending to-be-closed variables are closed, and callers that wait for it in `resume` receive `false` and `"cannot resume dead coroutine"`. Closing a detached coroutine that failed returns `false` and its error object, which counts as collecting that error. [Cancelling](/manual/concurrency#cancelling) describes detached coroutines in full.

A coroutine closes the same way at the end of the scope of a `<close>` variable that holds it, and when a [loop over the coroutine](/manual/guide#looping-over-a-coroutine) ends before the coroutine does. There, an error object of the close is raised, and a coroutine that is running or normal is left as it is.

```lus
local co = coroutine.create(function()
    local res <close> = setmetatable({}, { __close = function() print("released") end })
    coroutine.yield()
end)
coroutine.resume(co)
do
    local c <close> = co
end                           --> released
print(coroutine.status(co))   --> dead
```
