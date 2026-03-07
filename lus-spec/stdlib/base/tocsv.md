---
name: tocsv
module: base
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: t
    type: table
  - name: delimiter
    type: string
    optional: true
returns: string
---

Converts a table of rows `t` to a CSV string. Each row must be a sequential table of values. Non-string values are converted via `tostring`; `nil` values produce empty fields. Fields containing the delimiter, newlines, or double quotes are automatically quoted. The optional `delimiter` defaults to `","`.
