---
name: utf8.codes
module: utf8
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: s
    type: string
returns: function
---

Return an iterator function that traverses `s`, returning the byte position and codepoint of each UTF-8 character.
