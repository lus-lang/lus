---
name: vector.archive.deflate.decompress
module: vector.archive.deflate
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

Decompresses raw deflate data and returns the bytes as a vector.

- `data` is the compressed input, a vector or a string. A string supplies its WTF-8 bytes, so compressed data, which is rarely valid text, travels as a vector.
- `max` is the largest decompressed size in bytes. It defaults to 536,870,912 (512 MiB), and a value of 0 or less also selects the default.

The function returns one vector. Raw deflate carries no header and no checksum, so the function validates only the structure of the compressed blocks. Data with an invalid block structure raises `deflate decompress failed` with the reason in parentheses, such as `InvalidBlockType`. Data that ends early, including an empty input, raises `deflate decompress: incomplete data`. Output that would grow past `max` raises `decompressed size exceeds limit (N bytes)`, which stops a small input from expanding without bound. An input that is neither a string, a number, nor a vector raises `bad argument #1 to 'decompress' (string or vector expected)`.

The following example decompresses data, then decompresses it again with a limit below its size.

```lus
local packed = vector.archive.deflate.compress(string.rep("ab", 500))
local bytes = vector.archive.deflate.decompress(packed)
print(#bytes, vector.tostring(bytes, 0, 6))  --> 1000  ababab
print(catch vector.archive.deflate.decompress(packed, 100))
--> false  ...: decompressed size exceeds limit (100 bytes)
```

A program that compressed text decodes the result with [`vector.tostring`](/manual/api#vector.tostring). [`vector.archive.deflate.compress`](/manual/api#vector.archive.deflate.compress) produces the data that this function reads.
