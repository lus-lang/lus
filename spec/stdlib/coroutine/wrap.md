---
name: coroutine.wrap
module: coroutine
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: f
    type: function
returns: function
---

`coroutine.wrap(f)` creates a coroutine whose body is the function `f` and returns a function that resumes it each time it is called.

The parameter `f` must be a function, and any other value raises `bad argument #1 to 'wrap' (function expected, got TYPE)`. The arguments of each call to the wrapper are passed to the coroutine as [`coroutine.resume`](/manual/api#coroutine.resume) passes them, and the wrapper returns the values that the coroutine yields or returns, without the leading boolean.

An error inside the coroutine propagates to the caller of the wrapper. The wrapper closes the failed coroutine first, and a string error object gets the position of the wrapper call as a prefix, so it carries two positions, as in `script.lus:9: script.lus:8: boom`. Calling the wrapper after the coroutine is dead raises `cannot resume dead coroutine`.

```lus
local next_id = coroutine.wrap(function()
    for id = 1, 2 do
        coroutine.yield(id)
    end
end)

print(next_id(), next_id())  --> 1  2
print(select("#", next_id()))  --> 0
print((catch next_id()))  --> false
```

A wrapper works as the iterator of a generic `for`, which stops when the coroutine yields or returns `nil`. [`coroutine.create`](/manual/api#coroutine.create) returns the coroutine itself, which suits code that needs its status or wants failures as values.
