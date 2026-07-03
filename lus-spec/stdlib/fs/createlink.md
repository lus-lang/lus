---
name: fs.createlink
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:write"]
origin: lus
params:
  - name: target
    type: string
  - name: link
    type: string
returns: boolean
---

Creates a symbolic link at `link` pointing to `target`. Returns `true` on success, or `nil` plus an error message on failure.
