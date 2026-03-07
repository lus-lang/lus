---
name: fromcsv
module: base
kind: function
since: 1.6.0
stability: unstable
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

Parses a CSV string `s` and returns a table of rows. Each row is a sequential table of string values. When `headers` is `true`, the first row is used as column headers and subsequent rows are returned as tables keyed by those headers. The optional `delimiter` defaults to `","`.
