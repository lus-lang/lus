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

Terminates the program. The optional `code` argument is the exit code (`true` means success, `false` means failure, default is `true`). If `close` is true, closes the Lua state before exiting.
