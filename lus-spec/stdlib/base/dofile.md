---
name: dofile
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: filename
    type: string
    optional: true
returns: any
---

Opens and executes the contents of `filename` as a Lus chunk. When called without arguments, executes from standard input. Returns all values returned by the chunk. Requires `load` and `fs:read` pledges.
