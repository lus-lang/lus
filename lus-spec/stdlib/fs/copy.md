---
name: fs.copy
module: fs
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: source
    type: string
  - name: dest
    type: string
returns: boolean
---

Copies the file at `source` to `dest`. Returns `true` on success, or `nil` plus an error message on failure. Requires `fs:read` and `fs:write` pledges.
