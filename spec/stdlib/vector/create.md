---
name: vector.create
module: vector
kind: function
since: 0.1.0
stability: stable
origin: lus
fastcall: true
params:
  - name: capacity
    type: integer
  - name: fast
    type: boolean
    optional: true
returns: vector
---

Returns a new vector of a given size with every byte set to zero.

- `capacity` is the size of the vector in bytes, an integer of 0 or more.
- `fast` is accepted for compatibility with earlier releases and has no effect. The bytes start at zero with or without it.

The function returns one vector. A negative `capacity` raises `bad argument #1 to 'vector.create' (capacity must be non-negative)`, a float without an integer value raises `bad argument #1 to 'vector.create' (number has no integer representation)`, and a missing `capacity` raises `bad argument #1 to 'vector.create' (number expected, got no value)`.

The following example creates a vector and reads its size and first byte.

```lus
local v = vector.create(1024)
print(#v, vector.get(v, 0))  --> 1024  0
print(#vector.create(0))  --> 0
```

A vector created with size 0 is valid, and [`vector.resize`](/manual/api#vector.resize) grows it later. [`vector.fromstring`](/manual/api#vector.fromstring) creates a vector that holds the bytes of a string.
