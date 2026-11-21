---
name: vector.tostring
module: vector
kind: function
since: 2.0.0
stability: stable
origin: lus
params:
  - name: v
    type: vector
  - name: i
    type: integer
    optional: true
  - name: j
    type: integer
    optional: true
  - name: mode
    type: string
    optional: true
returns: string
---

Decodes a range of bytes of a vector as WTF-8 text and returns the string.

- `v` is the vector to decode.
- `i` is the zero-based offset of the first byte to decode. It defaults to 0.
- `j` is the offset just past the last byte to decode. It defaults to the size of the vector.
- `mode` is `"strict"` or `"lossy"`. It defaults to `"strict"`.

Both offsets are clamped to the vector, and a range with `j` at or before `i` gives the empty string. With `mode` set to `"strict"`, input that is not valid WTF-8 raises `invalid UTF-8 at byte N`, where `N` is the offset of the first invalid sequence. With `mode` set to `"lossy"`, each invalid sequence becomes U+FFFD. Any other `mode` raises an error that names it, such as `bad argument #4 to 'tostring' (invalid option 'raw')`, and a `v` that is not a vector raises `bad argument #1 to 'tostring' (vector expected)`.

The following example decodes a whole vector, a prefix, and a prefix that cuts a character in half.

```lus
local v = vector.fromstring("héllo")
print(vector.tostring(v))                 --> héllo
print(vector.tostring(v, 0, 1))           --> h
print(vector.tostring(v, 0, 2, "lossy"))  --> h�
print(catch vector.tostring(v, 0, 2))     --> false  ...: invalid UTF-8 at byte 1
```

Lone surrogates are valid WTF-8, so a vector made by [`vector.fromstring`](/manual/api#vector.fromstring) always decodes back to the same string. The decompression functions of `vector.archive` return vectors, and this function turns decompressed text back into a string.
