---
name: vector.get
module: vector
kind: function
since: 2.0.0
stability: stable
origin: lus
params:
  - name: v
    type: vector
  - name: offset
    type: integer
returns: integer|nil
---

Returns the byte at a zero-based offset of a vector as an integer from 0 to 255, or `nil` when the offset lies outside the vector.

- `v` is the vector to read.
- `offset` is the zero-based position of the byte, an integer.

An offset below 0, or at or after the size of the vector, returns `nil`. A `v` that is not a vector raises `bad argument #1 to 'get' (vector expected)`, and a missing or non-integer `offset` raises `bad argument #2 to 'get'`.

The following example reads bytes inside and outside a vector.

```lus
local v = vector.fromstring("AZ")
print(vector.get(v, 0), vector.get(v, 1))      --> 65  90
print(vector.get(v, 2), vector.get(v, -1))     --> nil  nil
```

[`vector.set`](/manual/api#vector.set) stores a byte, and [`vector.unpack`](/manual/api#vector.unpack) reads several bytes as one value.
