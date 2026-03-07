---
name: vector.archive.deflate.decompress
module: vector.archive.deflate
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: data
    type: string|vector
returns: string|vector
---

Decompresses raw deflate-compressed `data`. No header or checksum validation is performed. Returns the same type as the input.
