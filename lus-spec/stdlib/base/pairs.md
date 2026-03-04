---
name: pairs
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: t
    type: table
returns: function
---

Returns an iterator function, the table `t`, and `nil`, so that the construction `for k, v in pairs(t)` iterates over all key--value pairs of `t`. If `t` has a `__pairs` metamethod, calls it with `t` as argument and returns its results.
