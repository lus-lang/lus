---
name: type
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: v
    type: any
returns: string
---

Returns the type of `v` as a string: `"nil"`, `"number"`, `"string"`, `"boolean"`, `"table"`, `"function"`, `"thread"`, `"userdata"`, `"vector"`, or `"enum"`.
