---
name: vector.archive.lz4.decompress
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

Decompresses data in the current LZ4 frame format and returns the bytes as a vector.

- `data` is the compressed input, a vector or a string. A string supplies its WTF-8 bytes, so compressed data, which is rarely valid text, travels as a vector.
- `max` is the largest decompressed size in bytes. It defaults to 536,870,912 (512 MiB), and a value of 0 or less also selects the default.

The function returns one vector. The function validates the frame header and, when the frame carries them, the checksums. Data that is not a valid frame raises `lz4 decompress failed` followed by the reason, such as `ERROR_frameType_unknown`. Data that ends early, including an empty input, raises `lz4 decompress: incomplete data`. Output that would grow past `max` raises `decompressed size exceeds limit (N bytes)`, which stops a small input from expanding without bound. An input that is neither a string, a number, nor a vector raises `bad argument #1 to 'decompress' (string or vector expected)`.

The following example decompresses data, then decompresses it again with a limit below its size.

```lus
local packed = vector.archive.lz4.compress(string.rep("ab", 500))
local bytes = vector.archive.lz4.decompress(packed)
print(#bytes, vector.tostring(bytes, 0, 6))  --> 1000  ababab
print(catch vector.archive.lz4.decompress(packed, 100))
--> false  ...: decompressed size exceeds limit (100 bytes)
```

A program that compressed text decodes the result with [`vector.tostring`](/manual/api#vector.tostring). [`vector.archive.lz4.compress`](/manual/api#vector.archive.lz4.compress) produces the data that this function reads. [`vector.archive.lz4.decompress_hc`](/manual/api#vector.archive.lz4.decompress_hc) reads the legacy LZ4 frame format.
