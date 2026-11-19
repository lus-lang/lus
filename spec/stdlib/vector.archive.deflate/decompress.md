---
name: vector.archive.deflate.decompress
module: vector.archive.deflate
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: data
    type: vector|string
returns: vector
---

Decompresses raw deflate-compressed `data`. No header or checksum validation is performed. Accepts a vector or a string and returns the decompressed bytes as a vector. A program that compressed text decodes the result with `vector.tostring`.
