---
name: string.char
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
vararg: true
returns: string
---

Returns a string with one character for each argument, where each argument is the code point of its character.

Each argument is an integer from 0 to 0x10FFFF. A float, bigint, or decimal with an integral value and a numeric string are accepted as well. With no arguments the result is the empty string. The surrogate code points from 0xD800 to 0xDFFF are accepted and kept as lone surrogates, which WTF-8 represents.

A code point outside the range raises the error `value out of range`, and a number with no integral value raises `number has no integer representation`. The message names the position of the argument.

```lus
print(string.char(72, 105))  --> Hi
print(string.char(233, 0x1F600))  --> é😀
print(#string.char(0xD800))  --> 1
print(catch string.char(0x110000))  --> false  ...: bad argument #1 to 'string.char' (value out of range)
```

Concatenating a string that ends with a lead surrogate and a string that starts with a trail surrogate joins the pair into one supplementary character. [`string.byte`](/manual/api#string.byte) returns the code points of a string, and [`string.len`](/manual/api#string.len) counts its characters.
