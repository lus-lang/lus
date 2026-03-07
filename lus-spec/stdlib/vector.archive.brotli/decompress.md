---
name: vector.archive.brotli.decompress
module: vector.archive.brotli
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: data
    type: string|vector
returns: string|vector
---

Decompresses Brotli-compressed `data`. Returns the same type as the input.
