---
name: vector.archive.lz4.compress
module: vector.archive.lz4
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: data
    type: string|vector
  - name: level
    type: integer
    optional: true
returns: vector
---

Compresses `data` using LZ4 frame format. The optional `level` (1-12, default 1) controls the speed-ratio trade-off. Accepts a string or a vector and returns the compressed bytes as a vector.
