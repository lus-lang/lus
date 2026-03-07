---
name: vector.archive.brotli.compress
module: vector.archive.brotli
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: data
    type: string|vector
  - name: quality
    type: integer
    optional: true
  - name: lgwin
    type: integer
    optional: true
returns: string|vector
---

Compresses `data` using Brotli format (RFC 7932). The optional `quality` (0-11, default 11) controls compression quality. The optional `lgwin` (10-24, default 22) sets the LZ77 window size. Returns the same type as the input.
