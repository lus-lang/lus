---
name: string.match
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
returns: string|nil
---

Look for the first match of `pattern` in string `s`. Returns the captures from the match, or the whole match if there are no captures. Returns `nil` if no match is found.
