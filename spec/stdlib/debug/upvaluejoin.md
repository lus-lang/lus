---
name: debug.upvaluejoin
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: f1
    type: function
  - name: n1
    type: integer
  - name: f2
    type: function
  - name: n2
    type: integer
---

Makes upvalue `n1` of closure `f1` refer to the same upvalue as `n2` of closure `f2`.
