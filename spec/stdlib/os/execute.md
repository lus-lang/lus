---
name: os.execute
module: os
kind: function
since: 0.1.0
stability: stable
pledges: ["exec"]
origin: lua
params:
  - name: command
    type: string
    optional: true
returns: boolean|nil
---

Runs `command` in the system shell, waits for it to finish, and returns whether it succeeded, how it ended, and its exit status or signal number.

`command` is a command string. It runs under `/bin/sh -c` on POSIX systems, and under `cmd.exe /s /c` on Windows, which receives the command exactly as written. The runtime flushes its standard output before the command starts, so earlier output appears first.

With a command, the call returns three values: `true` when the command exited with status 0 and `nil` otherwise, then `"exit"` when the command exited or `"signal"` when a signal ended it, then the exit status or the signal number. On Windows the exit number is the full 32-bit exit code of the process, so a crash code such as `3221225477` reads as a failure. A command that cannot be started returns `nil` and a message. Running a command requires the `exec` permission, and without it the call raises `permission "exec" denied for os.execute`.

Without `command`, the call returns `true` to report that a shell is available, and it needs no permission. A build without process support returns `false` instead.

```lus
pledge("exec")
print(os.execute("true"))     --> true  exit  0
print(os.execute("exit 3"))   --> nil  exit  3
print(os.execute())           --> true
```

[`io.popen`](/manual/api#io.popen) runs a command and connects a pipe to its output or input.
