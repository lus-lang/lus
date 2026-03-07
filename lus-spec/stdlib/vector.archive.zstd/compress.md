---
name: vector.archive.zstd.compress
module: vector.archive.zstd
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

Compresses `data` using Zstandard format (RFC 8878). The optional `level` (-7 to 22, default 3) controls the speed-ratio trade-off. Returns the same type as the input.
