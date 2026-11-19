---
name: string.gsub
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
  - name: repl
    type: string|table|function
  - name: n
    type: integer
    optional: true
returns: string
---

Return a copy of `s` where all (or the first `n`) occurrences of `pattern` are replaced by `repl`. The replacement `repl` can be a string, table, or function. Also returns the total number of substitutions as a second value.
