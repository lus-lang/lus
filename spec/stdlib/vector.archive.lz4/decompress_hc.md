---
name: vector.archive.lz4.decompress_hc
module: vector.archive.lz4
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: data
    type: vector|string
  - name: max
    type: integer
    optional: true
returns: vector
---

Decompresses data in the legacy LZ4 frame format and returns the bytes as a vector.

- `data` is the compressed input, a vector or a string.
- `max` is the largest decompressed size in bytes. It defaults to 536,870,912 (512 MiB), and a value of 0 or less also selects the default.

The legacy format starts with the magic number `0x184C2102`, stored little endian, and older LZ4 tools produced it. A sequence of blocks follows, each a 4-byte little-endian size and a raw LZ4 block that decodes to at most 8 MiB. A size field that holds the magic number of a current or skippable LZ4 frame ends the legacy content. The function returns one vector.

Data that does not start with the legacy magic number, including a current LZ4 frame, raises `lz4 decompress_hc: not a legacy LZ4 frame`. A block that runs past the end of the input raises `lz4 decompress_hc: truncated block`, and a block that does not decode raises `lz4 decompress_hc: corrupt block`. Output that would grow past `max` raises `decompressed size exceeds limit (N bytes)`.

The following example builds a legacy frame by hand. It holds one block of six bytes, a token that announces five literal bytes followed by those bytes.

```lus
local v = vector.create(14)
vector.pack(v, 0, "<I4I4Bc5", 0x184C2102, 6, 0x50, "hello")
print(vector.tostring(vector.archive.lz4.decompress_hc(v)))  --> hello
print(catch vector.archive.lz4.decompress(v))
--> false  ...: lz4 decompress failed: ERROR_frameType_unknown
```

The library writes only the current frame format, so new data goes through [`vector.archive.lz4.compress`](/manual/api#vector.archive.lz4.compress) and [`vector.archive.lz4.decompress`](/manual/api#vector.archive.lz4.decompress).
