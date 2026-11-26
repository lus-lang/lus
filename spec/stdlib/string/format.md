---
name: string.format
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: formatstring
    type: string
vararg: true
returns: string
---

Returns a string built from `formatstring`, in which each directive is replaced by the next argument, formatted as the directive describes.

`formatstring` holds text and directives in the style of C `printf`. A directive is `%`, then optional flags among `-`, `+`, space, `#`, and `0`, then an optional width of at most two digits, then an optional precision of a dot and at most two digits, then a conversion letter. The remaining arguments supply one value for each directive, in order. `%%` writes a percent sign and takes no argument.

The conversions treat the number subtypes as follows:

- `%d` and `%i` write an integer in decimal. They accept an integer, a float or decimal with an integral value, a numeric string, and a bigint whose numeral has at most 16,384 digits, which they write exactly. `%u` is the same.
- `%x`, `%X`, and `%o` write an integer in hexadecimal or octal. A negative integer is written as its 64-bit two's complement, and a bigint must fit in 64 bits.
- `%c` writes the character whose code point is the argument.
- `%f`, `%F`, `%e`, `%E`, `%g`, `%G`, `%a`, and `%A` write a float. A decimal is written from its exact digits under `%f`, `%e`, and `%g`, rounded half to even, so `string.format("%.2f", 2.675d)` is `"2.68"`. A bigint, and a decimal under `%a`, are first converted to the nearest float. An infinity is written as `inf` and a NaN as `nan`, in capitals under the uppercase conversions. A NaN is written without a minus sign on every platform, and the `+` flag writes it as `+nan`.
- `%s` writes any value as [`tostring`](/manual/api#tostring) converts it, so a `__tostring` metamethod applies. The width and the precision count characters.
- `%q` writes a value as a Lus literal that reads back as the same value. A string is written in double quotes, with quotes, backslashes, and control characters escaped, and a newline is written as a backslash followed by a newline. An integer is written in decimal, except `math.mininteger`, which is written in hexadecimal. A finite float is written as a hexadecimal float, infinity as `1e9999`, and NaN as `(0/0)`. `nil`, `true`, and `false` are written as their keywords.

The result is always a string.

A missing argument raises `bad argument #n to 'format' (no value)`, where `n` is the position of the argument. An unknown conversion raises `invalid conversion '%y' to 'format'`, and a width or precision of more than two digits raises `invalid conversion specification`. A value with no integral value passed to an integer conversion raises `number has no integer representation`. `%c` with a code point above 0x10FFFF raises `value out of range`. `%q` with a table or function raises `value has no literal form`.

```lus
print(string.format("%d items at %.2f", 3, 9.5))  --> 3 items at 9.50
print(string.format("[%5s][%-5s]", "é", "ab"))  --> [    é][ab   ]
print(string.format("%x %X %o %c", 255, 255, 8, 233))  --> ff FF 10 é
print(string.format("%d", 2n ^ 70))  --> 1180591620717411303424
print(string.format("%q", 'say "hi"\t'))  --> "say \"hi\"\9"
print(string.format("%q %q", 0.5, math.mininteger))  --> 0x1p-1 0x8000000000000000
print(catch string.format("%d", 1.5))  --> false  ...: bad argument #2 to 'format' (number has no integer representation)
```

`%q` writes a bigint and a decimal as their digits with no suffix, so the literal reads back as an integer or a float. [`string.rep`](/manual/api#string.rep) repeats a string, and [`tostring`](/manual/api#tostring) converts one value without a format.
