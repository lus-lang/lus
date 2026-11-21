---
name: utf8.codepoint
module: utf8
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
  - name: lax
    type: boolean
    optional: true
returns: integer
---

`utf8.codepoint(s, i, j, lax)` returns the code points of the characters of `s` from character position `i` through `j`, one integer per character.

The parameters select the characters:

- `s` is the string.
- `i` is the first position and defaults to `1`.
- `j` is the last position and defaults to `i`, so a call with only `s` returns the code point of the first character.
- `lax`, when truthy, accepts lone surrogates. The default is `false`.

Positions count characters, and a negative position counts back from the end, so `-1` is the last character. When `i` is greater than `j`, `utf8.codepoint` returns no values. An `i` below 1 raises `bad argument #2 to 'utf8.codepoint' (out of bounds)`, and a `j` past the end raises the same error for argument 3, which includes any call on the empty string with the default positions. Without `lax`, a lone surrogate raises `invalid UTF-8 code`.

```lus
print(utf8.codepoint("héllo"))          --> 104
print(utf8.codepoint("héllo", 2))       --> 233
print(utf8.codepoint("héllo", -2, -1))  --> 108  111
```

[`utf8.char`](/manual/api#utf8.char) builds a string from code points, and [`string.byte`](/manual/api#string.byte) returns code points as well.
