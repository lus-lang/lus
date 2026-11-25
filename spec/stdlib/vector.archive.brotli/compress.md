---
name: vector.archive.brotli.compress
module: vector.archive.brotli
kind: function
since: 1.6.0
stability: stable
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
returns: vector
---

Compresses a string or a vector in the Brotli format (RFC 7932) and returns the compressed bytes as a vector.

- `data` is the input, a string or a vector. A number is converted to its textual form first.
- `quality` sets the trade between speed and ratio, an integer from 0 to 11. It defaults to 11. Quality 0 is the fastest, and quality 11 produces the smallest output.
- `lgwin` sets the LZ77 window to 2 to the power `lgwin` bytes, an integer from 10 to 24. It defaults to 22.

The function returns one vector. The output is a Brotli stream. Compressing the empty string returns a short valid stream that decompresses to zero bytes. An input that is neither a string, a number, nor a vector raises `bad argument #1 to 'compress' (string or vector expected)`. A `quality` outside its range raises `bad argument #2 to 'compress' (quality must be 0-11)`, and a float without an integer value raises `bad argument #2 to 'compress' (number has no integer representation)`. An `lgwin` outside its range raises `bad argument #3 to 'compress' (lgwin must be 10-24)`.

The following example compresses repeated text, decompresses it, and passes an invalid quality.

```lus
local text = string.rep("hello world ", 100)
local packed = vector.archive.brotli.compress(text)
print(type(packed), #packed < #text)  --> vector  true
local back = vector.archive.brotli.decompress(packed)
print(vector.tostring(back) == text)  --> true
print(#vector.archive.brotli.compress(text, 3, 16) < #text)  --> true
print(catch vector.archive.brotli.compress(text, 99))
--> false  ...: bad argument #2 to 'compress' (quality must be 0-11)
```

[`vector.archive.brotli.decompress`](/manual/api#vector.archive.brotli.decompress) reverses this function. The [compression](/manual/text#compression) section of the manual compares all five formats.
