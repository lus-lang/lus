---
name: vector.archive.zstd.decompress
module: vector.archive.zstd
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: data
    type: string|vector
returns: string|vector
---

Decompresses Zstandard-compressed `data`. Validates the frame header and optional content checksum. Returns the same type as the input.
