---
name: vector.clone
module: vector
kind: function
since: 0.1.0
stability: stable
origin: lus
fastcall: true
params:
  - name: v
    type: vector
returns: vector
---

Returns a new vector with the same size and bytes as a given vector.

- `v` is the vector to copy.

The copy is independent, so a change to either vector leaves the other unchanged. A `v` that is not a vector raises `bad argument #1 to 'vector.clone' (vector expected)`.

The following example changes a copy and reads both vectors.

```lus
local v = vector.fromstring("abc")
local copy = vector.clone(v)
vector.set(copy, 0, 65)
print(vector.tostring(v), vector.tostring(copy))  --> abc  Abc
print(copy == v, #copy)  --> false  3
```

Two vectors are equal only when they are the same object, so a clone never compares equal to its original. [`vector.fromstring`](/manual/api#vector.fromstring) given a vector also returns a copy.
