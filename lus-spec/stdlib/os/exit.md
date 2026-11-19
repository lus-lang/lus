---
name: os.exit
module: os
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: code
    type: boolean|integer
    optional: true
  - name: close
    type: boolean
    optional: true
---

On the main interpreter, terminates the process. The optional `code` argument is the exit code (`true` means success, `false` means failure, default is `true`). If `close` is true, closes the Lua state before exiting.

Inside a worker, raises the catchable error `"os.exit is unavailable in a worker"`. A caught call leaves the worker running. An uncaught call becomes the worker execution error observed by its parent.
