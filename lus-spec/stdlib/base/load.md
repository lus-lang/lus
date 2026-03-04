---
name: load
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: chunk
    type: string|function
  - name: chunkname
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

Loads a chunk. If `chunk` is a string, the chunk is that string. If it is a function, it is called repeatedly to get the chunk pieces. Returns the compiled chunk as a function, or `nil` plus an error message on failure. The optional `chunkname` names the chunk for error messages, `mode` controls whether text (`"t"`), binary (`"b"`), or both (`"bt"`, default) are allowed, and `env` sets the first upvalue as the chunk's environment. Requires the `load` pledge.
