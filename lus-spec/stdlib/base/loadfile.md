---
name: loadfile
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: filename
    type: string
    optional: true
  - name: mode
    type: string
    optional: true
  - name: env
    type: table
    optional: true
returns: function|nil
---

Loads a chunk from `filename` (or standard input if absent) without executing it. Returns the compiled chunk as a function, or `nil` plus an error message on failure. See `load` for the meaning of `mode` and `env`. Requires `load` and `fs:read` pledges.
