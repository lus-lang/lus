---
name: vector.unpack
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
returns: any
---

Reads values from a vector at an offset, in the binary layout of a format string, and returns them followed by the offset just past the last byte read.

- `v` is the vector to read.
- `offset` is the zero-based position of the first byte to read.
- `fmt` is a format string, with the options of [`string.unpack`](/manual/api#string.unpack).

The function returns one value per option of the format, then the offset after the bytes it read. An empty format returns only `offset`. An offset below 0 or after the end raises `bad argument #2 to 'unpack' (offset out of bounds)`, and a read that runs past the end raises `bad argument #2 to 'unpack' (data too short)`. An unknown option raises `invalid format option`.

The following example reads a length-prefixed string and then the integer after it.

```lus
local v = vector.create(16)
vector.pack(v, 0, "<s1I4", "hey", 513)
local text, next = vector.unpack(v, 0, "<s1")
print(text, next)                      --> hey  4
print(vector.unpack(v, next, "<I4"))   --> 513  8
print(catch vector.unpack(v, 14, "<I4"))   --> false  ...: bad argument #2 to 'unpack' (data too short)
```

[`vector.pack`](/manual/api#vector.pack) writes values in the same layout, and [`vector.unpackmany`](/manual/api#vector.unpackmany) reads the same format repeatedly.
