---
name: coroutine.create
module: coroutine
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: f
    type: function
returns: thread
---

`coroutine.create(f)` creates a coroutine whose body is the function `f` and returns it as a value of type `"thread"`.

The parameter `f` must be a function, and any other value raises `bad argument #1 to 'create' (function expected, got TYPE)`. The new coroutine is suspended and runs nothing until [`coroutine.resume`](/manual/api#coroutine.resume) starts it, passing the arguments of that first `resume` to `f`.

A coroutine starts with the permissions of the coroutine that creates it. From then on the two permission sets are independent, so a [`pledge`](/manual/api#pledge) inside the coroutine stays inside it.

```lus
local co = coroutine.create(function(a, b)
    return a + b
end)

print(type(co), coroutine.status(co))  --> thread  suspended
print(coroutine.resume(co, 2, 3))  --> true  5
print(coroutine.status(co))  --> dead
```

[`coroutine.wrap`](/manual/api#coroutine.wrap) creates a coroutine and returns a function that resumes it, and [`coroutine.detach`](/manual/api#coroutine.detach) hands a coroutine to the runtime. [Coroutines](/manual/guide#coroutines) in the guide describes how coroutines transfer control.
