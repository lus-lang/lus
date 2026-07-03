---
name: fs.remove
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:write"]
origin: lus
params:
  - name: path
    type: string
returns: boolean
---

Removes the file or directory at `path`. Returns `true` on success, or `nil` plus an error message on failure.
