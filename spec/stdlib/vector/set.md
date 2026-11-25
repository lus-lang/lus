---
name: vector.set
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
  - name: byte
    type: integer
---

Stores a byte at a zero-based offset of a vector and returns no values.

- `v` is the vector to write into.
- `offset` is the zero-based position of the byte, from 0 to one less than the size of the vector.
- `byte` is the value to store, an integer from 0 to 255.

Offsets of the `vector` functions count from 0, while a slice `v[i, j]` counts from 1 and includes `j`, as [Slices](/manual/guide#slices) describes. `vector.set(v, 0, byte)` therefore writes the byte that the slice `v[1, 1]` copies.

An offset outside the vector raises `bad argument #2 to 'set' (offset out of bounds)`, and a value outside 0 to 255 raises `bad argument #3 to 'set' (byte out of range)`. A missing or non-integer `offset` or `byte` raises a `bad argument` error for that argument, and a `v` that is not a vector raises `bad argument #1 to 'set' (vector expected)`.

The following example writes a byte and then tries a write past the end.

```lus
local v = vector.create(4)
vector.set(v, 0, 255)
print(vector.get(v, 0))              --> 255
print(catch vector.set(v, 4, 1))     --> false  ...: bad argument #2 to 'set' (offset out of bounds)
print(catch vector.set(v, 0, 256))   --> false  ...: bad argument #3 to 'set' (byte out of range)
```

[`vector.resize`](/manual/api#vector.resize) grows a vector before a write past its end, and [`vector.get`](/manual/api#vector.get) reads a byte.
