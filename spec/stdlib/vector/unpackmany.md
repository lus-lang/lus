---
name: vector.unpackmany
module: vector
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: v
    type: vector
  - name: offset
    type: integer
  - name: fmt
    type: string
  - name: count
    type: integer
    optional: true
returns: function
---

Returns an iterator that repeatedly unpacks values from `v` using the format `fmt`. Optional `count` limits the number of iterations.

```lus
for a, b in vector.unpackmany(v, 0, "I4I4") do
  print(a, b)
end
```
