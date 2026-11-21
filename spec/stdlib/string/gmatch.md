---
name: string.gmatch
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
returns: function
---

Returns an iterator function that returns the next match of `pattern` in `s` each time it is called, as the captures of the match or as the whole match when the pattern has no captures.

`s` is the string to search, and `pattern` is a [pattern](/manual/guide#strings-and-patterns). A number in either place is converted to its textual form. `init` is the character position where the search starts. It defaults to 1, and a negative value counts back from the end of `s`.

Each call of the iterator returns the captures of the next match, with a position capture `()` yielding an integer, or the whole match. After the last match it returns `nil`, which ends a generic `for` loop.

A malformed pattern raises its error at the first call of the iterator.

```lus
for key, value in string.gmatch("a=1, b=2", "(%w+)=(%w+)") do
    print(key, value)
end
--> a  1
--> b  2
for word in string.gmatch("one two three", "%a+", 5) do
    io.write(word, ";")
end
print()  --> two;three;
```

A pattern that matches the empty string yields an empty match at every position, including the position after the last character, so `string.gmatch("abc", "x*")` yields four empty strings. A `^` at the start of the pattern matches a literal `^`. Patterns match whole characters, so `.` yields one character at a time. [`string.find`](/manual/api#string.find) returns the positions of one match, and [`string.gsub`](/manual/api#string.gsub) replaces every match.
