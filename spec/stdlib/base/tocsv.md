---
name: tocsv
module: base
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: t
    type: table
  - name: delimiter
    type: string
    optional: true
returns: string
---

`tocsv(t, delimiter)` converts the sequence of rows `t` to CSV text and returns the string.

The parameter `t` is a sequence of rows, and each row is a sequence of field values. The optional `delimiter` is the field separator, exactly one character, and defaults to `","`.

Each row becomes one line that ends with `"\n"`, including the last. A field is converted with [`tostring`](/manual/api#tostring), so numbers, booleans, and tables with `__tostring` work, and a `nil` field produces an empty field. A field that contains the delimiter, a line break, or a double quote is enclosed in double quotes, and each quote inside it is doubled. The empty table returns the empty string. The length of `t` and of each row is taken with `#`, which honors `__len`.

A row that is not a table raises `row N is not a table`. A delimiter that is not exactly one character raises `bad argument #2 to 'tocsv' (delimiter must be a single character)`.

```lus
io.write(tocsv({ { "name", "quote" }, { "Ada", 'said "hi"' } }))
--> name,quote
--> Ada,"said ""hi"""
io.write(tocsv({ { 1, nil, true } }, ";"))  --> 1;;true
```

[`fromcsv`](/manual/api#fromcsv) parses CSV text back into rows. A header row is written as the first row of `t`.
