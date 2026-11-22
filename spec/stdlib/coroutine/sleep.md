---
name: coroutine.sleep
module: coroutine
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: seconds
    type: number|duration
returns: thread
---

Returns a coroutine whose resume waits until `seconds` have passed and then ends it.

`seconds` is a number of seconds, which may have a fraction, or a `duration` from the `time` library. The time runs from the first resume, not from the call, so a coroutine made early waits its whole time when the program resumes it. Resuming it returns `true` once the time has passed, with no other values. The coroutine is then dead, so a second resume returns `false` and `"cannot resume dead coroutine"`. A time of zero returns at the first resume.

Resumed from a detached coroutine, the wait suspends that coroutine while the other detached coroutines run. Resumed anywhere else, it blocks while the detached coroutines run. Closing the coroutine with `coroutine.close` ends the sleep. Closing a detached coroutine that waits in a resume of the sleep closes the sleep too, so a cancelled task never keeps the program waiting for its sleep.

A negative or NaN time raises `bad argument #1 to 'sleep' (the time must not be negative)`, and a value that is neither a number nor a duration raises a bad argument error.

The following example measures a sleep of 50 milliseconds.

```lus
local start = time.monotonic()
print(coroutine.resume(coroutine.sleep(0.05)))            --> true
print((time.monotonic() - start):seconds() >= 0.05)       --> true
```

[`coroutine.detach`](/manual/api#coroutine.detach) runs tasks that sleep side by side.
