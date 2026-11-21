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

Ends the process with the exit code `code`.

`code` is optional. `true` or no argument exits with status 0, `false` exits with status 1, and an integer exits with that status. `close` is accepted for compatibility and has no effect. The runtime flushes its buffered output and then ends the process at once, so pending `<close>` variables, `__gc` finalizers, and detached coroutines do not run. The function requires no permission.

```lus nocheck
io.write("saving... ")
os.exit(false)   -- the process ends with status 1
```

Inside a worker, `os.exit` raises the catchable error `"os.exit is unavailable in a worker"`. A caught call leaves the worker running, and an uncaught call becomes the error of the worker that its creator observes through [`worker.receive`](/manual/api#worker.receive).

The example is fenced as a fragment because it ends the process that runs it. A program that needs its cleanup to run returns from its main chunk.
