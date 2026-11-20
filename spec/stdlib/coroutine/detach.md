---
name: coroutine.detach
module: coroutine
kind: function
since: 2.0.0
stability: stable
origin: lus
params:
  - name: co
    type: thread
vararg: true
returns: thread
---

Hands the suspended coroutine `co` to the runtime and returns `co`. The runtime resumes the coroutine by itself: the first time with the extra arguments, and afterwards whenever what the coroutine waits for is ready. For a coroutine that has not started, the extra arguments are the arguments of its body. For a coroutine that already ran and yielded, they are the results of its pending `coroutine.yield`.

`detach` returns at once and the coroutine starts on its next turn. Detached coroutines take turns in the order in which they became ready. Inside a detached coroutine, a blocking operation such as `receive` on a socket suspends the coroutine while the other coroutines run, and `coroutine.yield` gives the next turn to the others.

`coroutine.resume(co)` waits until a detached coroutine has ended and returns what `resume` returns for a coroutine that ends: `true` and the results of the body, or `false` and the error. `coroutine.close(co)` cancels it.

Raises an error when `co` is running, normal, dead, already detached, or the main thread.

```lus
local function worker(name, count)
    for i = 1, count do
        print(name, i)
        coroutine.yield()
    end
    return name .. " is done"
end

local a = coroutine.detach(coroutine.create(worker), "a", 2)
local b = coroutine.detach(coroutine.create(worker), "b", 2)
print(coroutine.resume(a)) -- a 1, b 1, a 2, b 2, then: true  a is done
print(coroutine.resume(b)) -- true  b is done
```
