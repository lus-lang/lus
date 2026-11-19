---
name: string.transcode
module: string
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: input
    type: string|vector
  - name: from
    type: string
  - name: to
    type: string
  - name: ignorebad
    type: boolean
    optional: true
returns: string|vector
---

Converts `input` from encoding `from` to encoding `to`. The input may be a string or a vector. The result is a vector when `to` is a byte encoding and a string when `to` is a text encoding.

The byte encodings are `"utf-16le"`, `"utf-16be"`, `"utf-32le"`, `"utf-32be"`, `"iso-8859-1"` (also `"latin1"` and `"latin-1"`), and `"binary"`, which stands for the raw bytes. The text encodings are `"utf-8"`, `"utf-8bom"`, `"ascii"`, and the binary to text encodings `"base64"`, `"url"`, and `"hex"`. Decoding `"base64"`, `"url"`, or `"hex"` input yields its raw bytes, which are then converted to `to`.

Invalid input, and a character that the target encoding cannot represent, raise an error that names the position. When `ignorebad` is true, such sequences and characters are skipped.

```lus
local bytes = string.transcode("hé", "utf-8", "utf-16le")   -- a vector of 4 bytes
local text = string.transcode(bytes, "utf-16le", "utf-8")   -- "hé"
local b64 = string.transcode("hi", "utf-8", "base64")       -- "aGk="
```
