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

`coroutine.detach(co, ...)` hands the suspended coroutine `co` to the runtime, which resumes it by itself from then on, and returns `co`.

The parameter `co` is a suspended coroutine. The extra arguments are passed on the first resume. For a coroutine that has not started, they are the arguments of its body. For a coroutine that already ran and yielded, they are the results of its pending `coroutine.yield`.

`detach` returns at once, and the coroutine starts on its next turn. A _detached coroutine_ is one that `detach` handed to the runtime. Detached coroutines take turns in the order in which they became ready, and each runs until it waits, yields, or ends. Inside a detached coroutine, a blocking operation such as `receive` on a socket suspends the coroutine while the others run, and [`coroutine.yield`](/manual/api#coroutine.yield) gives the next turn to the others. When the main chunk returns, `lus` keeps running the detached coroutines until every one of them has ended.

[`coroutine.resume`](/manual/api#coroutine.resume) on a detached coroutine waits until it has ended and returns `true` and the results of the body, or `false` and the error object. [`coroutine.close`](/manual/api#coroutine.close) cancels it. A detached coroutine whose error nothing collects stops the program with that error.

Detaching raises an error when `co` is the main thread, or when it is running, normal, dead, or already detached. The messages are `cannot detach the main thread`, `cannot detach a running coroutine`, `cannot detach a normal coroutine`, `cannot detach a dead coroutine`, and `cannot detach a detached coroutine`. A detached coroutine keeps the last message after it has ended.

```lus
local log = {}

local function worker(name)
    for i = 1, 2 do
        log[#log + 1] = name .. i
        coroutine.yield()
    end

    return name .. " is done"
end

local a = coroutine.detach(coroutine.create(worker), "a")
local b = coroutine.detach(coroutine.create(worker), "b")
print(coroutine.resume(a))  --> true  a is done
print(table.concat(log, " "))  --> a1 b1 a2 b2
```

[Coroutines and workers](/manual/concurrency) describes detached coroutines in full, including suspension points and errors that nothing collects.
