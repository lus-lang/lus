---
name: debug.format
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: source
    type: string
  - name: chunkname
    type: string
    optional: true
  - name: indent_width
    type: integer
    optional: true
returns: string
---

Formats Lus source code. Returns the formatted source string.

The optional `chunkname` specifies the name used in error messages. The optional `indent_width` sets the indentation width (defaults to 2).
