---
name: loadfile
module: base
kind: function
since: 0.1.0
stability: stable
pledges: ["load", "fs:read"]
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

Loads a chunk from `filename` or standard input without executing it. Returns the compiled chunk as a function, or `nil` plus an error message on failure. See `load` for the meaning of `mode` and `env`.

Binary chunks are version-dependent artifacts for trusted build and storage paths. Treat every binary chunk as trusted input. Use `mode = "t"` for a file supplied across an untrusted boundary.
