---
name: utf8.offset
module: utf8
kind: function
since: 0.1.0
stability: deprecated
origin: lua
fastcall: true
params:
  - name: s
    type: string
  - name: n
    type: integer
  - name: i
    type: integer
    optional: true
returns: integer|nil
---

`utf8.offset` is deprecated, because positions count characters, so the `n`th character from position `i` is at position `i + n - 1`.

`utf8.offset(s, n, i)` returns the character position of the `n`th character of `s` counted from position `i`, twice, or `nil` when that character lies outside `s`.

The parameters select the character:

- `s` is the string.
- `n` is the count. A positive `n` counts forward, with `1` meaning the character at `i`. A negative `n` counts backward from the character before `i`. An `n` of `0` means the character at `i`.
- `i` is the starting position. It defaults to `1` when `n` is positive or zero and to `#s + 1` when `n` is negative. A negative `i` counts back from the end.

Each character occupies exactly one position, so both results are the same position, matching the start and end positions that Lua returns. A count that reaches exactly one past the last character returns `#s + 1`. An `i` below 1 or more than one past the end raises `bad argument #3 to 'utf8.offset' (position out of bounds)`.

```lus
print(utf8.offset("héllo", 3))  --> 3  3
print(utf8.offset("héllo", -1))  --> 5  5
print(utf8.offset("héllo", 2, 3))  --> 4  4
print(utf8.offset("héllo", 7))  --> nil
```

Character positions are plain integers in Lus, so [`string.sub`](/manual/api#string.sub) accepts the result directly.
