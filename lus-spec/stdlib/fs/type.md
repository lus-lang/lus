---
name: fs.type
module: fs
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: path
    type: string
returns: string|nil
---

Returns the type of the filesystem entry at `path` as a string: `"file"`, `"directory"`, `"link"`, or `nil` if it does not exist. Requires `fs:read` pledge.
