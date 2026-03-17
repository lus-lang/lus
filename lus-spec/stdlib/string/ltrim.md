---
name: string.ltrim
module: string
kind: function
since: 1.6.0
stability: unstable
origin: lus
fastcall: true
params:
  - name: s
    type: string
  - name: chars
    type: string
    optional: true
returns: string
---

Removes leading characters from string `s`. If `chars` is not provided, removes whitespace (space, tab, newline, carriage return). Otherwise removes all contiguous characters present in `chars` from the left.
