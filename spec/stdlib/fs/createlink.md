---
name: fs.createlink
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:write"]
origin: lus
params:
  - name: link
    type: string
  - name: target
    type: string
returns: []
---

Creates a symbolic link at `link` pointing to `target`. Successful calls complete with an empty result list. Failures raise catchable errors.
