---
name: string.sub
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
  - name: j
    type: integer
    optional: true
returns: string
---

Returns the substring of `s` from character position `i` through character position `j`, inclusive.

`s` is the string to cut. A number is converted to its textual form first. `i` is the position of the first character, and it is required. `j` is the position of the last character and defaults to -1, the end of the string. Positions count characters, and a negative position counts back from the end, so -1 names the last character and -3 the third from last.

The result is a string. Positions outside the string are clamped to it: a start before the first character starts at the first, and an end past the last character stops at the last. When the range holds no character, because `i` is past `j` or past the end, the result is the empty string.

A missing `i` raises `bad argument #2 to 'string.sub' (number expected, got no value)`. A position with no integral value, or a bigint outside 64 bits, raises `number has no integer representation`. A position may be any number subtype with an integral value, or a numeric string.

```lus
local s = "héllo"
print(s:sub(2), s:sub(2, 3), s:sub(-3))   --> éllo  él  llo
print(s:sub(-3, -2), s:sub(0), s:sub(2, 100))  --> ll  héllo  éllo
print(s:sub(4, 2) == "", s:sub(10) == "")  --> true  true
print(s[2, 3])                             --> él
```

The slice `s[i, j]` takes the same range as `s:sub(i, j)` when both positions lie between 1 and the length. A slice treats a position below 1 as 1 and runs backward when its start is greater than its end, as the [slices](/manual/guide#slices) section describes. ASCII strings reach any position in constant time, and a long non-ASCII string finds a position through an index of every 64th character. [`string.byte`](/manual/api#string.byte) returns the code points of a range, and [`string.len`](/manual/api#string.len) counts the characters.
