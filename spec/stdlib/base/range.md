---
name: range
module: base
kind: function
since: 2.0.0
stability: stable
origin: lus
params:
  - name: start
    type: number
  - name: limit
    type: number
    optional: true
  - name: step
    type: number
    optional: true
returns: function
---

Returns an iterator over the numbers from `start` to `limit` inclusive, advancing by `step`, which defaults to 1. With a single argument, `range(n)` counts from 1 to `n`. A negative `step` counts down. A `step` of zero raises an error.

```lus
for i in range(1, 5) do print(i) end          --> 1 2 3 4 5
for i in range(10, 1, -3) do print(i) end     --> 10 7 4 1
for i in range(3) do print(i) end             --> 1 2 3
```

When a `for` loop calls `range` directly, the compiler emits the same numeric loop as `for i = start, limit, step`. Anywhere else, `range` returns an ordinary iterator function, state, and control value that any generic `for` can consume.
