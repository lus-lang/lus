---
name: io.read
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
vararg: true
returns: string|nil
---

Reads from the default input file according to the given formats. Formats: `"n"` reads a number, `"a"` reads the whole file, `"l"` reads a line (default, strips newline), `"L"` reads a line keeping the newline, or an integer *n* reads *n* bytes.
