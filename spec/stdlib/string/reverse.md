---
name: string.reverse
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: s
    type: string
returns: string
---

Returns a string with the characters of `s` in reverse order.

`s` is the string to reverse. A number is converted to its textual form first.

The result is a string with the same characters as `s`, with one exception. A lone trail surrogate followed by a lone lead surrogate comes out as the lead followed by the trail, and the two join into one supplementary character, as they do when two strings are concatenated. Such a result is one character shorter for each pair, and reversing it again does not give back `s`. Text without lone surrogates reverses back to itself. The empty string reverses to itself.

An argument that is neither a string nor a number raises `bad argument #1 to 'string.reverse' (string expected, got nil)` with its type.

```lus
print(string.reverse("héllo"))   --> olléh
print(("abc"):reverse())         --> cba
print(string.reverse(123))       --> 321
```

Reversal works on characters, so a multi-byte character such as `é` stays whole. A combining mark, which is a code point of its own, moves to the other side of the character it follows. [`string.sub`](/manual/api#string.sub) takes a range of characters.
