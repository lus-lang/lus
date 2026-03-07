---
name: vector.archive.deflate.compress
module: vector.archive.deflate
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: data
    type: string|vector
  - name: level
    type: integer
    optional: true
returns: string|vector
---

Compresses `data` using raw deflate format (RFC 1951) without headers. The optional `level` (0-9, default 6) controls the compression ratio. Returns the same type as the input.
