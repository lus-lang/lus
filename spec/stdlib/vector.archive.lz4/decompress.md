---
name: vector.archive.lz4.decompress
module: vector.archive.lz4
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: data
    type: vector|string
returns: vector
---

Decompresses LZ4 frame-compressed `data`. Validates the frame header and optional checksum. Accepts a vector or a string and returns the decompressed bytes as a vector. A program that compressed text decodes the result with `vector.tostring`.
