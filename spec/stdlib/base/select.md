---
name: select
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: index
    type: integer|string
vararg: true
returns: any
---

If `index` is a number, returns all arguments after argument number `index`. If `index` is the string `"#"`, returns the total number of extra arguments.
