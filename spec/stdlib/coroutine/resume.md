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

Starts or resumes execution of coroutine `co`. On the first resume, the extra arguments are passed to the coroutine body function. On subsequent resumes, the extra arguments become the results of the yield that suspended the coroutine.

Returns `true` plus any values passed to `yield` or returned by the body, or `false` plus an error message on failure.

For a coroutine given to `coroutine.detach`, `resume` waits until the coroutine has ended and returns `true` plus the results of its body, or `false` plus its error. The extra arguments are ignored. A coroutine that ended earlier keeps its results until the first `resume` collects them, and every caller that was already waiting when it ended receives them too. A later `resume` returns `false` and `"cannot resume dead coroutine"`, as it does for any dead coroutine. While it waits, a detached caller is suspended, and any other caller runs the detached coroutines of the program.
