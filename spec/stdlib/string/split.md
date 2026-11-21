---
name: string.split
module: string
kind: function
since: 1.6.0
stability: stable
origin: lus
fastcall: true
params:
  - name: s
    type: string
  - name: delimiter
    type: string
returns: table
---

Returns a new list of the substrings of `s` that lie between occurrences of `delimiter`.

`s` is the string to split. A number is converted to its textual form first. `delimiter` is a literal string, matched as plain text, so a `.` or `%` in it has no special meaning. It is required.

The result is a list of strings in order. Two delimiters in a row produce an empty string between them, and a delimiter at the start or the end produces an empty string at that end. A string that does not contain the delimiter returns a list with `s` alone, and the empty string returns a list with one empty string. An empty `delimiter` splits `s` into its characters, and splitting the empty string that way returns an empty list.

A missing `delimiter` raises `bad argument #2 to 'string.split' (string expected, got no value)`, and an `s` that is neither a string nor a number raises a type error.

```lus
local parts = string.split("a,b,,c", ",")
print(#parts, parts[1], parts[3] == "", parts[4])   --> 4  a  true  c
print(#string.split("a.b", "."))                    --> 2
local chars = string.split("héllo", "")
print(#chars, chars[2])                             --> 5  é
```

[`string.join`](/manual/api#string.join) is the inverse. [`string.gmatch`](/manual/api#string.gmatch) splits on a pattern, such as runs of whitespace.
