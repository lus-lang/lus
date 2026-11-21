---
name: string.ltrim
module: string
kind: function
since: 1.6.0
stability: stable
origin: lus
fastcall: true
params:
  - name: s
    type: string
  - name: chars
    type: string
    optional: true
returns: string
---

Returns a copy of `s` with the leading whitespace removed, or with the leading characters that belong to the set `chars` removed.

`s` is the string to trim. A number is converted to its textual form first. `chars` is a string whose characters form the set to remove, in any order, and each of them is removed wherever it repeats at the start. It defaults to the ASCII whitespace characters: space, tab, newline, vertical tab, form feed, and carriage return.

The result is a string. When every character of `s` belongs to the set, it is the empty string. An empty `chars` removes nothing.

A `s` that is neither a string nor a number raises `bad argument #1 to 'string.ltrim' (string expected, got nil)` with its type.

```lus
print("[" .. string.ltrim("  hi  ") .. "]")    --> [hi  ]
print(string.ltrim("--==hi", "-="))            --> hi
print(string.ltrim("ééa", "é"))                --> a
```

`chars` holds whole characters, so it may contain characters outside ASCII. The default set keeps Unicode spaces such as U+00A0. [`string.rtrim`](/manual/api#string.rtrim) trims the end, and [`string.trim`](/manual/api#string.trim) trims both ends.
