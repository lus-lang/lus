---
name: string.split
module: string
kind: function
since: 1.6.0
stability: unstable
origin: lus
fastcall: true
params:
  - name: s
    type: string
  - name: delimiter
    type: string
returns: table
---

Splits string `s` on the literal `delimiter`, returning a table of substrings. An empty delimiter splits into individual characters. Consecutive delimiters produce empty string entries.
