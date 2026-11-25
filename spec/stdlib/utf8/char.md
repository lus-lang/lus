---
name: utf8.char
module: utf8
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
vararg: true
returns: string
---

`utf8.char(...)` returns a string that holds one character for each code point argument, in order.

Each argument is an integer code point from 0 through 0x10FFFF, and surrogates are accepted. A value outside that range raises `bad argument #N to 'utf8.char' (value out of range)`, and a value that is not a number raises `number expected`. A call with no arguments returns the empty string.

```lus
local s = utf8.char(72, 233, 0x1F600)
print(s, #s)  --> Hé😀  3
print(utf8.char(0xD83D, 0xDE00) == utf8.char(0x1F600))  --> true
```

A lead surrogate followed directly by a trail surrogate joins into one supplementary character, as concatenation does. A lone surrogate stays a character of its own. [`utf8.codepoint`](/manual/api#utf8.codepoint) converts characters back to code points, and [`string.char`](/manual/api#string.char) builds strings from code points as well.
