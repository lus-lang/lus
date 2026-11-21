---
name: vector.resize
module: vector
kind: function
since: 0.1.0
stability: stable
origin: lus
fastcall: true
params:
  - name: v
    type: vector
  - name: newsize
    type: integer
---

Changes the size of a vector in place and returns no values.

- `v` is the vector to resize.
- `newsize` is the new size in bytes, an integer of 0 or more.

Bytes below the new size keep their values, bytes added at the end are zero, and bytes past a smaller size are discarded. A negative `newsize` raises `bad argument #2 to 'vector.resize' (size must be non-negative)`, and a `v` that is not a vector raises `bad argument #1 to 'vector.resize' (vector expected)`.

The following example grows a vector and then shrinks it.

```lus
local v = vector.create(4)
vector.set(v, 0, 255)
vector.resize(v, 8)
print(#v, vector.get(v, 0), vector.get(v, 7))  --> 8  255  0
vector.resize(v, 1)
print(#v, vector.get(v, 1))                    --> 1  nil
```

Every reference to the vector sees the new size, since the vector changes in place. [`vector.create`](/manual/api#vector.create) makes a new vector of a given size.
