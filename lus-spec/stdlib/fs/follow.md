---
name: fs.follow
module: fs
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: path
    type: string
returns: string
---

Resolves a symbolic link at `path` and returns the target path. Returns `nil` plus an error message on failure. Requires `fs:read` pledge.
