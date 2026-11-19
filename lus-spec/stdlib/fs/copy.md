---
name: fs.copy
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:read", "fs:write"]
origin: lus
params:
  - name: source
    type: string
  - name: dest
    type: string
returns: []
---

Copies the file at `source` to `dest`. Successful calls complete with an empty result list. Failures raise catchable errors.
