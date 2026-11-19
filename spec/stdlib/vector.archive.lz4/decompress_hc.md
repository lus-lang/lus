---
name: vector.archive.lz4.decompress_hc
module: vector.archive.lz4
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: data
    type: string|vector
returns: string|vector
---

Decompresses `data` written in the legacy LZ4 frame format, identified by the magic number `0x184C2102`. Older LZ4 tools produced this format, so `decompress_hc` reads archives written by them. New code should compress with `compress` and decompress with `decompress`, which use the current LZ4 frame format. Returns the same type as the input.
