---
name: fs.remove
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

Removes the file or directory at `path`. When `recursive` is true, directory contents are removed from the retained directory object. Authorization remains bound to the validated object through deletion. Successful calls complete with an empty result list. Failures raise catchable errors.
