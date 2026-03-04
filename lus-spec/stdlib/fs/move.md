---
name: fs.move
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

Moves (renames) the file or directory at `source` to `dest`. Returns `true` on success, or `nil` plus an error message on failure. Requires `fs:write` pledge.
