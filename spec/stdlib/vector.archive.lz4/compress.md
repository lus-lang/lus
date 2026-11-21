---
name: vector.archive.lz4.compress
module: vector.archive.lz4
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

Compresses a string or a vector in the LZ4 frame format and returns the compressed bytes as a vector.

- `data` is the input, a string or a vector. A number is converted to its textual form first.
- `level` sets the trade between speed and ratio, an integer from 1 to 12. It defaults to 1. Each level above 1 doubles the effort spent searching for matches, so higher levels compress more slowly and usually produce a smaller output.

The function returns one vector. The output is one frame in the current LZ4 frame format, which starts with the magic number `0x184D2204`. Compressing the empty string returns a short valid stream that decompresses to zero bytes. An input that is neither a string, a number, nor a vector raises `bad argument #1 to 'compress' (string or vector expected)`. A `level` outside its range raises `bad argument #2 to 'compress' (compression level must be 1-12)`, and a float without an integer value raises `bad argument #2 to 'compress' (number has no integer representation)`.

The following example compresses repeated text, decompresses it, and passes an invalid level.

```lus
local text = string.rep("hello world ", 100)
local packed = vector.archive.lz4.compress(text)
print(type(packed), #packed < #text)  --> vector  true
local back = vector.archive.lz4.decompress(packed)
print(vector.tostring(back) == text)  --> true
print(catch vector.archive.lz4.compress(text, 99))
--> false  ...: bad argument #2 to 'compress' (compression level must be 1-12)
```

[`vector.archive.lz4.decompress`](/manual/api#vector.archive.lz4.decompress) reverses this function. The [compression](/manual/text#compression) section of the manual compares all five formats.
