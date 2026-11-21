---
name: vector.archive.zstd.compress
module: vector.archive.zstd
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

Compresses a string or a vector in the Zstandard format (RFC 8878) and returns the compressed bytes as a vector.

- `data` is the input, a string or a vector. A number is converted to its textual form first.
- `level` sets the trade between speed and ratio, an integer from -131072 to 22. It defaults to 3. Negative levels compress faster with a lower ratio, and level 22 produces the smallest output.

The function returns one vector. The output is one Zstandard frame. Compressing the empty string returns a short valid stream that decompresses to zero bytes. An input that is neither a string, a number, nor a vector raises `bad argument #1 to 'compress' (string or vector expected)`. A `level` outside its range raises `bad argument #2 to 'compress' (compression level out of range)`, and a float without an integer value raises `bad argument #2 to 'compress' (number has no integer representation)`.

The following example compresses repeated text, decompresses it, and passes an invalid level.

```lus
local text = string.rep("hello world ", 100)
local packed = vector.archive.zstd.compress(text)
print(type(packed), #packed < #text)  --> vector  true
local back = vector.archive.zstd.decompress(packed)
print(vector.tostring(back) == text)  --> true
print(catch vector.archive.zstd.compress(text, 99))
--> false  ...: bad argument #2 to 'compress' (compression level out of range)
```

[`vector.archive.zstd.decompress`](/manual/api#vector.archive.zstd.decompress) reverses this function. The [compression](/manual/text#compression) section of the manual compares all five formats.
