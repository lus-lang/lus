---
name: fs.createlink
module: fs
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: target
    type: string
  - name: link
    type: string
returns: boolean
---

Creates a symbolic link at `link` pointing to `target`. Returns `true` on success, or `nil` plus an error message on failure. Requires `fs:write` pledge.
