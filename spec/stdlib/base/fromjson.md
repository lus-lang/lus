---
name: fromjson
module: base
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: s
    type: string|number
returns: any
---

Parses one complete JSON value from `s`. A numeric argument is converted to its textual form before parsing. Other argument types raise a type error. Integer syntax produces a Lus integer, while decimal or exponent syntax produces a float. Arrays become integer-keyed tables, objects become string-keyed tables, and JSON null becomes `nil`. Null fields are absent and null array elements create holes. Duplicate object keys keep the final value. Out-of-range numbers, trailing data, invalid syntax, and nesting beyond 1,000 levels raise an error with position information.
