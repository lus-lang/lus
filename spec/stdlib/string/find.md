---
name: string.find
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
  - name: init
    type: integer
    optional: true
  - name: plain
    type: boolean
    optional: true
returns: integer|nil
---

Look for the first match of `pattern` in string `s`. Returns the start and end indices of the match, plus any captures. Returns `nil` if no match is found. If `init` is given, the search starts at that position. If `plain` is true, performs a plain substring search with no pattern matching.
