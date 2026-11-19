---
name: io.popen
module: io
kind: function
since: 0.1.0
stability: stable
pledges: ["exec"]
origin: lua
params:
  - name: prog
    type: string
  - name: mode
    type: string
    optional: true
returns: userdata|nil
---

Starts program `prog` in a separate process and returns a file handle. Mode `"r"`, the default, reads the program's output. Mode `"w"` writes to its input.
