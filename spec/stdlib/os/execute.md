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

Passes `command` to the operating system shell for execution: `/bin/sh -c` on POSIX systems, and `cmd.exe /s /c` on Windows, which receives the command exactly as written. Returns `true` (or `nil` on failure), an exit type string (`"exit"` or `"signal"`), and the exit or signal number. On Windows the exit number is the full 32-bit exit code of the process, so a crash code such as `3221225477` reads as a failure.
