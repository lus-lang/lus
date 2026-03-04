---
name: io.close
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: file
    type: file
    optional: true
returns: boolean|nil
---

Closes `file`, or the default output file if no argument is given. Returns the status from the file close operation. For files opened with `io.popen`, returns the exit status.
