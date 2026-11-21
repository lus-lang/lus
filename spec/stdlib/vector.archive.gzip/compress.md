---
name: vector.archive.gzip.compress
module: vector.archive.gzip
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: data
    type: string|vector
  - name: level
    type: integer
    optional: true
returns: vector
---

Compresses a string or a vector in the gzip format (RFC 1952) and returns the compressed bytes as a vector.

- `data` is the input, a string or a vector. A number is converted to its textual form first.
- `level` sets the trade between speed and ratio, an integer from 0 to 9. It defaults to 6. Level 0 stores the data without compression, so the output is larger than the input, and level 9 produces the smallest output.

The function returns one vector. The output is a gzip header, deflate data, and a trailer with the CRC32 checksum and the length of the input. Compressing the empty string returns a short valid stream that decompresses to zero bytes. An input that is neither a string, a number, nor a vector raises `bad argument #1 to 'compress' (string or vector expected)`. A `level` outside its range raises `bad argument #2 to 'compress' (compression level must be 0-9)`, and a float without an integer value raises `bad argument #2 to 'compress' (number has no integer representation)`.

The following example compresses repeated text, decompresses it, and passes an invalid level.

```lus
local text = string.rep("hello world ", 100)
local packed = vector.archive.gzip.compress(text)
print(type(packed), #packed < #text)  --> vector  true
local back = vector.archive.gzip.decompress(packed)
print(vector.tostring(back) == text)  --> true
print(catch vector.archive.gzip.compress(text, 99))
--> false  ...: bad argument #2 to 'compress' (compression level must be 0-9)
```

[`vector.archive.gzip.decompress`](/manual/api#vector.archive.gzip.decompress) reverses this function. [`vector.archive.deflate.compress`](/manual/api#vector.archive.deflate.compress) writes the same compressed data with no header or checksum, and the [compression](/manual/text#compression) section of the manual compares all five formats.
