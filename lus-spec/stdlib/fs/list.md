---
name: fs.list
module: fs
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: path
    type: string
returns: table
---

Returns a table of filenames in the directory at `path`. Returns `nil` plus an error message on failure. Requires `fs:read` pledge.
