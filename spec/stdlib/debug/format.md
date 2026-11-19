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

Formats Lus source code and returns the formatted source string, or `nil` and an error message when the source does not parse. The source may also be given as a vector of bytes.

The optional `chunkname` specifies the name used in error messages. The optional `indent_width` sets the number of spaces per indentation level and defaults to 4. `lus fmt` formats files with the same formatter.
