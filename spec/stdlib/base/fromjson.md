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
  - name: options
    type: table
    optional: true
returns: any
---

Parses one complete JSON value from `s`. A numeric argument is converted to its textual form before parsing. Other argument types raise a type error. Integer syntax produces a Lus integer, while decimal or exponent syntax produces a float. Arrays become integer-keyed tables, objects become string-keyed tables, and JSON null becomes `nil`. Null fields are absent and null array elements create holes. Duplicate object keys keep the final value. Out-of-range numbers, trailing data, invalid syntax, and nesting beyond 1,000 levels raise an error with position information.

The optional `options` table takes the boolean field `exact`. With `exact` set, an integer that overflows 64 bits decodes as a bigint and a number with a fraction or an exponent decodes as a decimal, so `tojson` reproduces the original digits on the way back.

```lus
local n = fromjson('{"price": 19.90}', { exact = true }).price
print(math.type(n), n)   --> decimal  19.90
```
