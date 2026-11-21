---
name: utf8.len
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
returns: integer|nil
---

`utf8.len(s, i, j, lax)` returns the number of characters of `s` from character position `i` through `j`, or `nil` and the position of the first lone surrogate in that range.

The parameters select the range:

- `s` is the string.
- `i` is the first position and defaults to `1`.
- `j` is the last position and defaults to `-1`, the last character.
- `lax`, when truthy, counts lone surrogates like any other character. The default is `false`.

A negative position counts back from the end. With the defaults, `utf8.len(s)` equals `#s` for a string without lone surrogates. When `i` is greater than `j`, the result is `0`, and `i` may be one past the end. An `i` below 1 or more than one past the end raises `bad argument #2 to 'utf8.len' (initial position out of bounds)`, and a `j` past the end raises `bad argument #3 to 'utf8.len' (final position out of bounds)`.

```lus
print(utf8.len("hé😀"), utf8.len("héllo", 2, 3))   --> 3  2
local s = "ab" .. utf8.char(0xDC00) .. "c"
print(utf8.len(s))                               --> nil  3
print(utf8.len(s, 1, -1, true))                  --> 4
```

Lus strings are always well formed apart from lone surrogates, so a lone surrogate is the only character that strict mode rejects. [`utf8.offset`](/manual/api#utf8.offset) finds the position of a character.
