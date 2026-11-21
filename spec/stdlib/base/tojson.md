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

`tojson(value, filter)` serializes `value` as JSON text and returns the string.

The parameter `value` is the value to serialize. The optional `filter` is a function that can transform or omit values. A `filter` of another type raises `bad argument #2 to 'tojson' (function expected, got TYPE)`.

Values map to JSON as follows:

- A table whose keys are all positive integers becomes an array that runs from 1 through its largest key, with `null` in each missing position, so `{1, nil, 3}` becomes `[1,null,3]`. The empty table becomes `[]`. Trailing `nil` values have no key, so `{1, 2, nil}` becomes `[1,2]`. An array whose largest key is greater than 10 must hold more than half of its positions. A sparser one raises `excessively sparse array (largest key N with C elements)`.
- Every other table becomes an object that keeps its string keys and omits keys of other types. The order of object members is unspecified.
- Integers, and floats with an integral value, are written without a fraction, so `tojson(1.0)` is `"1"`. Other floats are written with the fewest significant digits, from 14 up to 17, that read back as the same float, so `tojson(0.1)` is `"0.1"`. Bigints and decimals are written with their exact digits.
- Infinite and NaN floats become `null`.
- Functions, threads, userdata, vectors, and enum values become `null` at the root or in arrays and are omitted from objects.

The filter is called first with `nil, value` for the root, then with each integer array key or string object key and its value. Its result is serialized recursively in place of the value, and a `nil` result omits a field or produces `null` at the root. A table whose metatable has a `__json` metamethod is serialized as the value that the metamethod returns.

Shared tables that form no cycle are serialized by value, once for each place they appear. A cycle raises `circular reference detected in table`. Serialization enforces a nesting limit of 1,000 levels, and a deeply nested table can raise a C stack overflow first.

```lus
print(tojson({ 1, "two", { x = false } }))   --> [1,"two",{"x":false}]
print(tojson({}), tojson(1.50d), tojson(0/0))   --> []  1.50  null

local hidden = tojson({ user = "ada", password = "secret" }, function(key, value)
    if key == "password" then return nil end
    return value
end)
print(hidden)                                 --> {"user":"ada"}
```

[`fromjson`](/manual/api#fromjson) parses JSON text, and [Data formats](/manual/data) gives the full mapping.
