---
name: os.execute
module: os
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: command
    type: string
    optional: true
returns: boolean|nil
---

Passes `command` to the operating system shell for execution. Returns `true` (or `nil` on failure), an exit type string (`"exit"` or `"signal"`), and the exit or signal number. Requires `exec` pledge.
