---
name: io.type
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: obj
    type: any
returns: string|nil
---

Returns `"file"` if `obj` is an open file handle, `"closed file"` if it is a closed file handle, or `nil` if it is not a file handle.
