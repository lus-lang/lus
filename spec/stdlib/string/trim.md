---
name: string.trim
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

Returns a copy of `s` with the leading and trailing whitespace removed, or with the leading and trailing characters that belong to the set `chars` removed.

`s` is the string to trim. A number is converted to its textual form first. `chars` is a string whose characters form the set to remove, in any order, and each of them is removed wherever it repeats at either end. It defaults to the ASCII whitespace characters: space, tab, newline, vertical tab, form feed, and carriage return.

The result is a string. Characters of the set inside the string, between other characters, stay. When every character of `s` belongs to the set, the result is the empty string. An empty `chars` removes nothing.

A `s` that is neither a string nor a number raises `bad argument #1 to 'string.trim' (string expected, got nil)` with its type.

```lus
print(`[$(string.trim("\t a b \n"))]`)  --> [a b]
print(string.trim("xxhixx", "x"))  --> hi
print(string.trim("--==hi=-", "-="))  --> hi
print(string.trim("aaa", "a") == "")  --> true
```

`chars` holds whole characters, so it may contain characters outside ASCII. The default set keeps Unicode spaces such as U+00A0. [`string.ltrim`](/manual/api#string.ltrim) and [`string.rtrim`](/manual/api#string.rtrim) trim one end.
