---
name: fs.list
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:read"]
origin: lus
params:
  - name: path
    type: string
returns: table
---

Returns a table of filenames in the directory at `path`. Returns `nil` plus an error message on failure.
