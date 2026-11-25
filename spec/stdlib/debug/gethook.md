---
name: debug.gethook
module: debug
kind: function
since: 0.1.0
pledges: ["debug"]
stability: stable
origin: lua
params:
  - name: thread
    type: thread
    optional: true
returns: function|nil
---

Returns the hook function, the hook mask, and the hook count installed on a thread, or `nil` when the thread has no hook.

- `thread` is the thread to inspect. It defaults to the running thread.

When a hook is installed, the function returns three values: the hook function, a string that holds the letters `c`, `r`, and `l` that the mask enables, always in that order, and the count, an integer that is 0 when no count hook is set. When no hook is installed, it returns a single `nil`. The function raises no errors of its own.

The following example installs a hook, reads it back, and removes it.

```lus
local function hook() end
debug.sethook(hook, "lc", 100)
local f, mask, count = debug.gethook()
print(f == hook, mask, count)    --> true  cl  100
debug.sethook()
print(debug.gethook())           --> nil
```

Each thread has its own hook, so `debug.gethook(co)` reports the hook of the coroutine `co` and nothing about the running thread. [`debug.sethook`](/manual/api#debug.sethook) installs and removes hooks.
