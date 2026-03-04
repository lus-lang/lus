---
name: io.popen
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: prog
    type: string
  - name: mode
    type: string
    optional: true
returns: userdata|nil
---

Starts the program `prog` in a separated process and returns a file handle for reading or writing, depending on `mode` (`"r"` for reading, default; `"w"` for writing). Requires `exec` pledge.
