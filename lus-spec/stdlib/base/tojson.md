---
name: tojson
module: base
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: value
    type: any
  - name: filter
    type: function
    optional: true
returns: string
---

Converts a Lus value to a JSON string. The optional `filter` argument controls serialization. Objects with a `__json` metamethod use it for custom serialization.
