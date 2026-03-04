---
name: io.open
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: filename
    type: string
  - name: mode
    type: string
    optional: true
returns: userdata|nil
---

Opens `filename` in the given `mode` and returns a file handle, or `nil` plus an error message on failure. Modes follow C `fopen` conventions: `"r"` (read, default), `"w"` (write), `"a"` (append), plus optional `"b"` for binary.
