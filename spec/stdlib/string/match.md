---
name: string.match
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
  - name: init
    type: integer
    optional: true
returns: string|nil
---

Searches `s` for the first match of `pattern` and returns its captures, or the whole match when the pattern has no captures.

`s` is the string to search, and `pattern` is a [pattern](/manual/guide#strings-and-patterns). A number in either place is converted to its textual form. `init` is the character position where the search starts. It defaults to 1, and a negative value counts back from the end of `s`.

On a match, the results are the captures in order, with a position capture `()` yielding a character position as an integer. A pattern without captures returns the whole match as one string. Without a match, the result is a single `nil`.

A malformed pattern raises an error that names the problem, such as `malformed pattern (missing ']')`.

```lus
print(string.match("key=val", "(%w+)=(%w+)"))         --> key  val
print(string.match("2024-01-02", "%d+-(%d+)"))        --> 01
print(string.match("héllo", "é.+"))                   --> éllo
print(string.match("héllo", "()l"))                   --> 3
print(string.match("  padded  ", "^%s*(.-)%s*$"))     --> padded
print(string.match("héllo", "x"))                     --> nil
```

An `init` before the first character searches from the first character, and an `init` more than one position past the end returns `nil`. Patterns match whole characters, and the classes such as `%a` describe ASCII characters only, so `string.match("é1", "%a")` is `nil`. [`string.find`](/manual/api#string.find) also returns the positions of the match, and [`string.gmatch`](/manual/api#string.gmatch) iterates over every match.
