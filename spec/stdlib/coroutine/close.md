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
