---
name: math.sqrt
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: x
    type: number
returns: number
---

Returns the square root of `x`, as a float.

`x` is a number of any subtype. An integer, a bigint, a decimal, and a numeric string are converted to the nearest float first.

The result is a non-negative float. A negative `x` returns NaN, and `math.huge` returns `inf`.

An argument that is not a number raises `bad argument #1 to 'math.sqrt' (number expected, got nil)` with its type.

```lus
print(math.sqrt(16))       --> 4.0
print(math.sqrt(2))        --> 1.4142135623730951
print(math.sqrt(2n^200))   --> 1.2676506002282294e+30
print(math.sqrt(-1))       --> nan
```

A bigint argument loses the digits that a float cannot hold, so the root of a large perfect square may differ from the exact root.
