---
name: coroutine.resume
module: coroutine
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: co
    type: thread
vararg: true
returns: boolean
---

`coroutine.resume(co, ...)` starts or continues the coroutine `co` and returns `true` and the values it yields or returns, or `false` and an error object when it fails.

The parameter `co` is the coroutine to run, and any other value raises `bad argument #1 to 'resume' (thread expected, got TYPE)`. On the first resume, the extra arguments are passed to the body of the coroutine. On later resumes, they become the results of the `coroutine.yield` that suspended it.

`resume` runs `co` until it yields, returns, or raises an error. The results are these:

- When `co` yields, `resume` returns `true` and the arguments of `coroutine.yield`.
- When the body returns, `resume` returns `true` and the results of the body, and `co` is dead.
- When the body raises an error, `resume` returns `false` and the error object, and `co` is dead.
- A dead coroutine returns `false` and `"cannot resume dead coroutine"`.
- A running or normal coroutine, including the one that calls `resume`, returns `false` and `"cannot resume non-suspended coroutine"`.

```lus
local co = coroutine.create(function(a, b)
    local c = coroutine.yield(a + b)
    return c * 2
end)

print(coroutine.resume(co, 1, 2))  --> true  3
print(coroutine.resume(co, 10))  --> true  20
print(coroutine.resume(co))  --> false  cannot resume dead coroutine
```

For a coroutine given to [`coroutine.detach`](/manual/api#coroutine.detach), `resume` waits until the coroutine has ended and returns `true` and the results of its body, or `false` and its error object. The extra arguments are ignored. A coroutine that ended earlier keeps its results until the first `resume` collects them, and every caller that was already waiting when it ended receives them too. A later `resume` returns `false` and `"cannot resume dead coroutine"`. While it waits, a detached caller is suspended, and any other caller runs the detached coroutines of the program. When the coroutines left can only wait for each other, the waiting `resume` returns `false` and `"deadlock: every coroutine waits for another coroutine"`.
