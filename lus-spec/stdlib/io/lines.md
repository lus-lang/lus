---
name: io.lines
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: filename
    type: string
    optional: true
vararg: true
returns: function
---

Returns an iterator function that reads from `filename` (or the default input if absent) according to the given formats. The file is automatically closed when the iterator finishes. Default format reads lines.
