---
name: vector.archive.lz4.decompress
module: vector.archive.lz4
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: data
    type: string|vector
returns: string|vector
---

Decompresses LZ4 frame-compressed `data`. Validates the frame header and optional checksum. Returns the same type as the input.
