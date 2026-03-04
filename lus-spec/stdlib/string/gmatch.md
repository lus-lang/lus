---
name: string.gmatch
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
returns: function
---

Return an iterator function that, each time it is called, returns the next captures from `pattern` in string `s`. If `pattern` has no captures, the whole match is returned. If `init` is given, the search starts at that position.
