---
name: string.find
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
  - name: plain
    type: boolean
    optional: true
returns: integer|nil
---

Searches `s` for the first match of `pattern` and returns the character positions where the match starts and ends, followed by its captures.

`s` is the string to search, and `pattern` is a [pattern](/manual/guide#strings-and-patterns). A number in either place is converted to its textual form. `init` is the character position where the search starts. It defaults to 1, and a negative value counts back from the end of `s`. When `plain` is true, `pattern` is a literal substring with no special characters. `plain` defaults to false, and passing it requires an `init`, which may be `nil`.

On a match, the first two results are the positions of the first and the last character of the match. The captures of the pattern follow, and a position capture `()` yields an integer. A pattern holds at most 32 captures, and one more raises `too many captures`, in every function that takes a pattern. Without a match, the result is a single `nil`.

A malformed pattern raises an error that names the problem, such as `malformed pattern (missing ']')` or `malformed pattern (ends with '%')`.

```lus
print(string.find("héllo wörld", "ö"))  --> 8  8
print(string.find("héllo", "l+"))  --> 3  4
print(string.find("key=val", "(%w+)="))  --> 1  4  key
print(string.find("a.b", ".", 1, true))  --> 2  2
print(string.find("héllo", "l", -2))  --> 4  4
print(string.find("héllo", "x"))  --> nil
```

An `init` before the first character searches from the first character. An `init` more than one position past the end returns `nil`, even for a pattern that matches the empty string. The empty pattern matches at `init` itself and returns `init` and `init - 1`. A pattern that starts with `^` matches only at `init`. Patterns match whole characters, so `.` matches one character and a set such as `[éà]` may hold any characters. The classes such as `%a` describe ASCII characters only. [`string.match`](/manual/api#string.match) returns the captures without the positions, and [`string.gmatch`](/manual/api#string.gmatch) iterates over every match.
