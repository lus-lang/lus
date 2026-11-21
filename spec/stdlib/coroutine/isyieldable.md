---
name: coroutine.isyieldable
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

`coroutine.isyieldable(co)` returns `true` when the coroutine `co` can yield and `false` otherwise.

The optional parameter `co` is the coroutine to ask about and defaults to the running coroutine. A value other than a coroutine raises `bad argument #1 to 'isyieldable' (thread expected, got TYPE)`.

The main thread never yields, so it returns `false`. The running coroutine cannot yield while a native function that does not support yielding is on its stack, such as the comparison function of `table.sort`. Every other coroutine returns `true`.

```lus
print(coroutine.isyieldable())   --> false
local co = coroutine.create(function()
    return coroutine.isyieldable()
end)
print(coroutine.resume(co))      --> true  true
```

A [`coroutine.yield`](/manual/api#coroutine.yield) where `isyieldable` returns `false` raises an error, `attempt to yield from outside a coroutine` in the main thread and `attempt to yield across a C-call boundary` inside a native call.
