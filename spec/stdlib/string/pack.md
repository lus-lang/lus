---
name: string.pack
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: fmt
    type: string
vararg: true
returns: vector
---

Returns a vector that holds the remaining arguments encoded in binary as the format string `fmt` describes.

`fmt` is a sequence of options. Each option that stores a value takes the next argument. Spaces between options are ignored. The options are:

- `<` sets little endian, `>` sets big endian, and `=` sets the native order. The native order is the default.
- `!n` sets the maximum alignment to `n` bytes, and `!` alone sets it to the native alignment. The default alignment is 1, which means no padding.
- `b` and `B` store a signed and an unsigned byte, `h` and `H` a 2-byte integer, `l`, `L`, `j`, `J`, and `T` an 8-byte integer, and `i[n]` and `I[n]` an integer of `n` bytes, from 1 to 16, with 4 as the default.
- `f`, `d`, and `n` store a float in 4, 8, and 8 bytes.
- `s[n]` stores a string preceded by its length in an unsigned integer of `n` bytes, 8 by default. `z` stores a string followed by a zero byte. `cn` stores a string of exactly `n` bytes, padded with zeros.
- `x` writes one zero byte of padding. `Xop` aligns to the size of the option `op` without storing a value.

The result is a new vector. Its size is the sum of the sizes of the options and their padding.

An integer that does not fit in its size raises `integer overflow`. A value with no integral value for an integer option raises `number has no integer representation`. A string for `z` that contains a zero raises `string contains zeros`, a string too long for the length of `s[n]` raises `string length does not fit in given size`, and a string longer than `n` for `cn` raises `string longer than given size`. A missing value raises `bad argument #n to 'pack' (number expected, got no value)`. An unknown option raises `invalid format option 'y'`, and a size outside 1 to 16 raises `integral size (17) out of limits [1,16]`.

```lus
local v = string.pack("<i4d", 7, 0.5)
print(type(v), #v)                      --> vector  12
print(string.unpack("<i4d", v))         --> 7  0.5  13
print(vector.get(string.pack(">I2", 258), 0))  --> 1
print(#string.pack("s1", "é"))          --> 3
```

An integer option accepts an integer, a float or decimal with an integral value, and a bigint that fits in the size. A float option accepts every subtype and stores the nearest float. A string option stores the WTF-8 bytes of a string, so lengths count bytes, not characters, and it accepts a vector in place of a string. [`string.unpack`](/manual/api#string.unpack) reads the values back, [`string.packsize`](/manual/api#string.packsize) returns the size of a fixed format, [`vector.pack`](/manual/api#vector.pack) writes into an existing vector, and [`vector.tostring`](/manual/api#vector.tostring) decodes packed text.
