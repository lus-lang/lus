---
name: vector.archive.zstd.decompress
module: vector.archive.zstd
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: data
    type: vector|string
returns: vector
---

Decompresses Zstandard-compressed `data`. Validates the frame header and optional content checksum. Accepts a vector or a string and returns the decompressed bytes as a vector. A program that compressed text decodes the result with `vector.tostring`.
