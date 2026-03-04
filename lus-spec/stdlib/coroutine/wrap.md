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

Creates a coroutine from function `f` and returns a function that resumes it each time it is called. Arguments to the wrapper are passed as extra arguments to `resume`. Returns the values passed to `yield`, excluding the first boolean. Raises an error on failure (unlike `resume`).
