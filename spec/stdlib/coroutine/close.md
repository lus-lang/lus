---
name: coroutine.close
module: coroutine
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: co
    type: thread
returns: boolean
---

Closes coroutine `co`, putting it in a dead state. If the coroutine was suspended with pending to-be-closed variables, those variables are closed. Returns `true` on success, or `false` plus an error message if closing a variable raises an error.

Closing a coroutine given to `coroutine.detach` cancels it: the runtime stops resuming it, its pending to-be-closed variables are closed, and callers that wait for it in `resume` receive `false` and `"cannot resume dead coroutine"`. Closing a detached coroutine that failed returns `false` plus its error, which counts as collecting that error.
