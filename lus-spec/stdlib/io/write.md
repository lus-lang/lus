---
name: io.write
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
vararg: true
returns: userdata|nil
---

Writes each argument to the default output file. Arguments must be strings or numbers. Returns the file handle on success, or `nil` plus an error message on failure.
