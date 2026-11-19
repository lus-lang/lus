---
name: string.transcode
module: string
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: s
    type: string
  - name: from
    type: string
  - name: to
    type: string
returns: string
---

Transcodes string `s` from encoding `from` to encoding `to`. Supported encodings depend on the platform.
