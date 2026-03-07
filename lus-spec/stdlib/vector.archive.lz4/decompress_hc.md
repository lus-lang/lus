---
name: vector.archive.lz4.decompress_hc
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

Decompresses LZ4 HC (legacy high-compression) format `data`. Provided for backward compatibility with older LZ4 HC implementations. Prefer `decompress` for new code. Returns the same type as the input.
