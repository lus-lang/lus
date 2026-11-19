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

Return a string containing the given code points, one character per argument. Code points up to U+10FFFF are accepted, including surrogates. An adjacent lead and trail surrogate join into one supplementary character, as concatenation does.
