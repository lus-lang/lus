---
name: string.byte
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: s
    type: string
  - name: i
    type: integer
    optional: true
  - name: j
    type: integer
    optional: true
returns: integer
---

Returns the code points of the characters of `s` from position `i` through position `j`, one integer per character.

`s` is the string to read. A number is converted to its textual form. `i` is the position of the first character and defaults to 1. `j` is the position of the last character and defaults to `i`. Positions count characters, and a negative position counts back from the end, so -1 names the last character.

The result is one integer for each character in the range, in order. A range that holds no character returns no values at all. That happens when `i` is greater than `j`, when `i` lies past the end of `s`, and when `s` is empty.

A position with no integral value, such as `1.5`, raises the error `number has no integer representation`. A position may be any number subtype with an integral value, or a numeric string.

```lus
print(string.byte("héllo"))  --> 104
print(string.byte("héllo", 2))  --> 233
print(string.byte("héllo", 1, -1))  --> 104  233  108  108  111
print(string.byte("abc", -10, 2))  --> 97  98
print(select("#", string.byte("abc", 10)))  --> 0
```

Positions outside the string are clamped to it. A start before the first character reads from the first character, and an end past the last character stops at the last one. The code point of `é` is 233 whatever its encoding, and the WTF-8 bytes of a string are available through [`vector.fromstring`](/manual/api#vector.fromstring). [`string.char`](/manual/api#string.char) builds a string from code points.
