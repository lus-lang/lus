---
name: fromcsv
module: base
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: s
    type: string
  - name: headers
    type: boolean
    optional: true
  - name: delimiter
    type: string
    optional: true
returns: table
---

`fromcsv(s, headers, delimiter)` parses the CSV text `s` and returns a table of its rows.

The parameters control the parse:

- `s` is the CSV text. Rows end at `"\n"`, `"\r\n"`, or `"\r"`, and a line ending at the very end of `s` adds no empty row.
- `headers`, when truthy, makes the first row a list of column names. The result then holds every following row as a table keyed by those names. The default is `false`.
- `delimiter` is the field separator, exactly one character. The default is `","`.

Without `headers`, the result is a sequence of rows, and each row is a sequence of strings. With `headers`, the result is a sequence of keyed rows, and a row shorter than the header has `nil` for its missing columns. Every field is a string, so numbers stay text until the program converts them. A quoted field may contain the delimiter, line breaks, and quotes written as `""`. The empty string returns an empty table.

A quoted field without its closing quote raises `CSV parse error at position N: unterminated quoted field`, and a character after a closing quote other than a delimiter or a line ending raises `CSV parse error at position N: unexpected character after quoted field`. Each message starts with the position of the call of `fromcsv`, as in the message of [`error`](/manual/api#error), and the position `N` counts characters of the text from 1. A delimiter that is not exactly one character raises `bad argument #3 to 'fromcsv' (delimiter must be a single character)`.

```lus
local rows = fromcsv("name,age\nAlice,30\nBob,17\n", true)
print(#rows, rows[1].name, rows[2].age)  --> 2  Alice  17
print(math.type(rows[1].age), type(rows[1].age))  --> nil  string

local plain = fromcsv('a;"b;c"\n1;2', false, ";")
print(plain[1][2], plain[2][1])  --> b;c  1
```

[`tocsv`](/manual/api#tocsv) writes rows back to CSV text, and [Data formats](/manual/data) describes the mapping in full.
