---
name: vector.archive.gzip.compress
module: vector.archive.gzip
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

Compresses `data` using gzip format. The optional `level` (0-9, default 6) controls the compression ratio. Returns the same type as the input.
