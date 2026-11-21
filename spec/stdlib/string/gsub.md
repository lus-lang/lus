---
name: string.gsub
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: s
    type: string
  - name: pattern
    type: string
  - name: repl
    type: string|table|function
  - name: n
    type: integer
    optional: true
returns: string
---

Returns a copy of `s` in which the matches of `pattern` are replaced by `repl`, followed by the number of matches that were replaced.

`s` is the string to search, and `pattern` is a [pattern](/manual/guide#strings-and-patterns). A number in either place is converted to its textual form. `repl` says what replaces each match:

- A string is copied, with `%1` through `%9` standing for the captures, `%0` for the whole match, and `%%` for a percent sign. A number is converted to a string first.
- A table is indexed with the first capture, or with the whole match when the pattern has no captures.
- A function is called with all the captures, or with the whole match when the pattern has no captures.

When the table lookup or the function call returns `false` or `nil`, the match stays as it was. A string or number result replaces the match. `n` is the largest number of replacements to make. It defaults to replacing every match, and a value of 0 or less replaces none.

The first result is the new string. The second is the number of matches replaced, which counts a match kept because of a `false` or `nil` result.

A `repl` of another type raises `bad argument #3 to 'gsub' (string/function/table expected, got boolean)` with its type. A table or function result of another type, such as a table, raises `invalid replacement value (a table)`. A replacement string with a capture index the pattern lacks raises `invalid capture index %2`, and a `%` followed by anything other than a digit or `%` raises `invalid use of '%' in replacement string`. A malformed pattern raises its error.

```lus
print(string.gsub("hello world", "o", "0"))                   --> hell0 w0rld  2
print(string.gsub("hello world", "o", "0", 1))                --> hell0 world  1
print(string.gsub("hello world", "(%w+)", "<%1>"))            --> <hello> <world>  2
print(string.gsub("$name is $x", "%$(%w+)", {name = "Ann"}))  --> Ann is $x  2
print(string.gsub("añb", ".", function(c) return c:upper() end))  --> AñB  3
```

Patterns match whole characters, so a replacement never splits a multi-byte character. The `ñ` in the last line stays lowercase because [`string.upper`](/manual/api#string.upper) changes ASCII letters only, and the classes such as `%a` likewise describe ASCII characters only. A pattern that matches the empty string matches at every position, so `string.gsub("abc", "", "-")` returns `-a-b-c-` and 4. [`string.find`](/manual/api#string.find) locates one match without replacing it.
