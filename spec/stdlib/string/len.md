---
name: string.len
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: s
    type: string
returns: integer
---

Returns the number of characters in `s`.

`s` is the string to measure. A number is converted to its textual form first.

The result is a non-negative integer. A character is one Unicode code point, including a lone surrogate, so `string.len("héllo")` is 5 and an emoji such as `😀` counts as 1. Embedded zeros count like any other character.

An argument that is neither a string nor a number raises `bad argument #1 to 'string.len' (string expected, got nil)` with its type.

```lus
print(string.len("héllo"), #"héllo")  --> 5  5
print(string.len("😀"), string.len(""))  --> 1  0
print(string.len("a\0b"))  --> 3
print(#vector.fromstring("héllo"))  --> 6
```

The `#` operator returns the same value for a string. The number of bytes of the WTF-8 encoding is the size of the vector that [`vector.fromstring`](/manual/api#vector.fromstring) returns, as the last line shows. [`string.sub`](/manual/api#string.sub) and [`string.byte`](/manual/api#string.byte) take positions in the same characters.
