---
name: vector.archive.gzip.decompress
module: vector.archive.gzip
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: data
    type: string|vector
returns: string|vector
---

Decompresses gzip-compressed `data`. Validates the gzip header and CRC32 checksum. Returns the same type as the input.
