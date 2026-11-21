---
name: coroutine.running
module: coroutine
kind: function
since: 0.1.0
stability: stable
origin: lua
returns: thread
---

`coroutine.running()` returns the running coroutine and a boolean that is `true` when the running coroutine is the main thread.

The main thread is the coroutine that runs the main chunk. It is a value of type `"thread"` like any other coroutine, and it can be passed to [`coroutine.status`](/manual/api#coroutine.status), which reports `"running"` for it while it runs.

```lus
local main, ismain = coroutine.running()
print(type(main), ismain)                 --> thread  true
local co = coroutine.create(function()
    local self, inmain = coroutine.running()
    return coroutine.status(self), inmain
end)
print(coroutine.resume(co))               --> true  running  false
```

[`coroutine.isyieldable`](/manual/api#coroutine.isyieldable) tells whether the running coroutine can yield.
