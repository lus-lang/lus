---
name: load
module: base
kind: function
since: 0.1.0
stability: stable
pledges: ["load"]
origin: lua
params:
  - name: chunk
    type: string|vector|function
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

Loads a chunk. If `chunk` is a string, the chunk is that string. If it is a vector, the chunk is its bytes, which is the form `string.dump` produces for binary chunks. If it is a function, it is called repeatedly to get the chunk pieces. Returns the compiled chunk as a function, or `nil` plus an error message on failure.

The optional arguments refine the load:

- `chunkname` names the chunk for error messages.
- `mode` controls whether text (`"t"`), binary (`"b"`), or both (`"bt"`, the default) are allowed.
- `env` sets the first upvalue as the chunk's environment.

Binary chunks are version-dependent artifacts for trusted build and storage paths. Treat every binary chunk as trusted input. Use `mode = "t"` when the chunk source crosses an untrusted boundary.
