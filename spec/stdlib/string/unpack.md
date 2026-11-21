---
name: string.unpack
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: fmt
    type: string
  - name: data
    type: vector|string
  - name: pos
    type: integer
    optional: true
returns: any
---

Reads the values that `data` holds in binary as the format string `fmt` describes, and returns them followed by the position of the first byte it did not read.

`fmt` is a format string with the options of [`string.pack`](/manual/api#string.pack). `data` is the vector to read, usually one that `string.pack` returned. A string is read through its WTF-8 bytes. `pos` is the 1-based byte position where reading starts. It defaults to 1, and a negative value counts back from the end of `data`.

The results are one value for each option that stores a value, in order, then the byte position after the last byte read. Integer options return integers and float options return floats. A string option returns a string when its bytes are valid WTF-8 and a vector of the bytes otherwise.

Data that ends before the format does raises `bad argument #2 to 'unpack' (data string too short)`. A `pos` outside the data raises `bad argument #3 to 'unpack' (initial position out of string)`. An option of more than 8 bytes whose value does not fit in 64 bits raises an error such as `9-byte integer does not fit into Lua Integer`.

```lus
local v = string.pack("<i2i2", 1, 2)
print(string.unpack("<i2i2", v))      --> 1  2  5
print(string.unpack("<i2", v, 3))     --> 2  5
print(string.unpack("<i2", v, -2))    --> 2  5
print(string.unpack("z", "hé\0rest")) --> hé  5
```

Positions count bytes, so a string argument with characters outside ASCII has more positions than characters. [`vector.unpack`](/manual/api#vector.unpack) reads the same formats with 0-based offsets, and [`string.packsize`](/manual/api#string.packsize) gives the size of a fixed format.
