---
name: io.output
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: file
    type: file|string
    optional: true
returns: userdata
---

When called with a filename, opens that file and sets it as the default output. When called with a file handle, sets it as the default output. When called with no arguments, returns the current default output file.
