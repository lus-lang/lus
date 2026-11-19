---
name: fs.createdirectory
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:write"]
origin: lus
params:
  - name: path
    type: string
  - name: recursive
    type: boolean
    optional: true
returns: []
---

Creates a directory at `path`. When `recursive` is true, missing parent directories are created in order. Successful calls complete with an empty result list. Failures raise catchable errors.
