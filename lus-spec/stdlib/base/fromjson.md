---
name: fromjson
module: base
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: s
    type: string
returns: any
---

Parses a JSON string `s` and returns the corresponding Lus value. Tables become Lus tables, JSON null becomes `nil`.
