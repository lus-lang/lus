---
name: vector.archive.gzip.decompress
module: vector.archive.gzip
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: data
    type: vector|string
returns: vector
---

Decompresses gzip-compressed `data`. Validates the gzip header and CRC32 checksum. Accepts a vector or a string and returns the decompressed bytes as a vector. A program that compressed text decodes the result with `vector.tostring`.
