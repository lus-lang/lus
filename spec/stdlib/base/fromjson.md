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

`fromjson(s, options)` parses one complete JSON value from `s` and returns it as a Lus value.

The parameter `s` is the JSON text. A numeric argument is converted to its textual form before parsing, and any other type raises `bad argument #1 to 'fromjson' (string expected, got TYPE)`. The optional `options` table takes the boolean field `exact`, which defaults to `false`. Other fields are ignored.

The value maps to Lus as follows:

- Integer syntax produces an integer, and syntax with a fraction or an exponent produces a float.
- Strings become strings, and `true` and `false` become booleans.
- Arrays become tables with integer keys from 1, and objects become tables with string keys.
- JSON `null` becomes `nil`, so a null field is absent and a null array element leaves a hole. `tojson` writes `null` in that hole again, except at the end of an array, where the hole has no key.
- An object with a duplicate key keeps the last value.

With `exact` set, an integer that overflows 64 bits decodes as a bigint and a number with a fraction or an exponent decodes as a decimal, so [`tojson`](/manual/api#tojson) reproduces the original digits on the way back.

Invalid syntax, trailing data after the value, empty input, a number out of range, and nesting deeper than 1,000 levels raise an error of the form `FILE:LINE: JSON parse error at position N: MESSAGE`. `FILE:LINE` is the position of the call of `fromjson`, as in the message of [`error`](/manual/api#error), and `N` counts characters of the text from 1.

```lus
local data = fromjson('{"name": "Alice", "scores": [95, 87.5], "note": null}')
print(data.name, data.scores[1], data.note)  --> Alice  95  nil
print(math.type(data.scores[1]), math.type(data.scores[2]))  --> integer  float

local n = fromjson('{"price": 19.90}', { exact = true }).price
print(math.type(n), n)  --> decimal  19.90
```

[Data formats](/manual/data) gives the full mapping between JSON and Lus values.
