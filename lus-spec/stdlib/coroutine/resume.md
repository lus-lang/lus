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

Starts or resumes execution of coroutine `co`. On the first resume, the extra arguments are passed to the coroutine body function. On subsequent resumes, the extra arguments become the results of the yield that suspended the coroutine. Returns `true` plus any values passed to `yield` or returned by the body, or `false` plus an error message on failure.
