---
name: vector.size
module: vector
kind: function
since: 0.1.0
stability: stable
origin: lus
fastcall: true
params:
  - name: v
    type: vector
returns: integer
---

Returns the size of a vector in bytes, the same value as `#v`.

- `v` is the vector to measure.

The function returns a non-negative integer. A `v` that is not a vector raises `bad argument #1 to 'vector.size' (vector expected)`, so the function never measures a string by mistake.

The following example measures a vector before and after a resize.

```lus
local v = vector.fromstring("héllo")
print(vector.size(v), #v)        --> 6  6
vector.resize(v, 0)
print(vector.size(v))            --> 0
```

[`vector.resize`](/manual/api#vector.resize) changes the size.
