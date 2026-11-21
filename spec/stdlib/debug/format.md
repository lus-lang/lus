---
name: debug.format
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: source
    type: string|vector
  - name: chunkname
    type: string
    optional: true
  - name: indent_width
    type: integer
    optional: true
returns: string|nil
---

Formats Lus source code and returns the formatted text, or `nil` and an error message when the source does not parse.

- `source` is the code to format, as a string or as a vector of bytes.
- `chunkname` names the chunk in the error message. It defaults to `"=format"`.
- `indent_width` is the number of spaces per indentation level. It defaults to 4, and a value of 0 or less also selects 4.

On success the function returns one string, which ends with a newline. If the source does not parse, it returns `nil` and the syntax error message, and it raises nothing.

A `source` that is neither a string, a number, nor a vector raises `bad argument #1 to 'format'`. An `indent_width` above 64 raises `bad argument #3 to 'format' (indent width too large)`.

The following example formats a one line chunk with two spaces per level and then reports a syntax error.

```lus
local text = debug.format("if ok then print( 1 ) end", nil, 2)
io.write(text)
--> if ok then
-->   print(1)
--> end
print(debug.format("local x = ", "input.lus"))
--> nil  [string "input.lus"]:1: unexpected symbol near <eof>
```

Comments keep their text. A comment that holds bytes that are not valid WTF-8 comes back with each invalid sequence replaced by U+FFFD. The `lus fmt` command formats files with the same formatter, and [`debug.parse`](/manual/api#debug.parse) returns the syntax tree that the formatter works from.
