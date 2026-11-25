---
name: vector.pack
module: vector
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: v
    type: vector
  - name: offset
    type: integer
  - name: fmt
    type: string
vararg: true
returns: integer
---

Writes values into a vector at an offset, in the binary layout of a format string, and returns the offset just past the last byte written.

- `v` is the vector to write into.
- `offset` is the zero-based position of the first byte to write.
- `fmt` is a format string, with the options of [`string.pack`](/manual/api#string.pack).
- The remaining arguments are the values that the format consumes, in order.

The function returns one integer, the offset after the written bytes. The vector keeps its size, so the bytes must fit. An offset below 0 or after the end raises `bad argument #2 to 'pack' (offset out of bounds)`, and a write that would pass the end raises `bad argument #2 to 'pack' (pack would exceed vector bounds)`. A missing value or a value that the option cannot hold raises an error for that argument, such as `bad argument #4 to 'pack' (unsigned overflow)`.

The following example writes three 32-bit little-endian integers and reads one back.

```lus
local v = vector.create(12)
print(vector.pack(v, 0, "<I4I4I4", 1, 2, 3))  --> 12
print(vector.unpack(v, 4, "<I4"))  --> 2  8
print(catch vector.pack(v, 10, "<I4", 7))  --> false  ...: bad argument #2 to 'pack' (pack would exceed vector bounds)
```

[`vector.resize`](/manual/api#vector.resize) makes room before a write past the end. [`vector.unpack`](/manual/api#vector.unpack) reads values in the same layout.
