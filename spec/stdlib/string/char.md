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

Return a string built from the given code points, one character per argument. Each argument is an integer from 0 to 0x10FFFF. Lone surrogate code points are accepted and kept as WTF-8.
