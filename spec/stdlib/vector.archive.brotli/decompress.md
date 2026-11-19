---
name: vector.archive.brotli.decompress
module: vector.archive.brotli
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: data
    type: vector|string
returns: vector
---

Decompresses Brotli-compressed `data`. Accepts a vector or a string and returns the decompressed bytes as a vector. A program that compressed text decodes the result with `vector.tostring`.
