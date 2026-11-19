---
name: fs.move
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:write"]
origin: lus
params:
  - name: source
    type: string
  - name: dest
    type: string
returns: []
---

Moves the file or directory at `source` to `dest`. Successful calls complete with an empty result list. Failures raise catchable errors.
