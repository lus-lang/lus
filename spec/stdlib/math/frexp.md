---
name: math.frexp
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: x
    type: number
returns: number
---

Returns the float `m` and the integer `e` such that `x` equals `m * 2^e`, where the absolute value of `m` lies in the range from 0.5 up to, but not including, 1.

`x` is a number of any subtype. An integer, a bigint, a decimal, and a numeric string are converted to the nearest float first.

The first result `m` is a float with the sign of `x`, and the second result `e` is an integer. A zero `x` returns 0.0 and 0. An infinity or NaN returns itself and 0.

An argument that is not a number raises `bad argument #1 to 'math.frexp' (number expected, got nil)` with its type.

```lus
print(math.frexp(8))       --> 0.5  4
print(math.frexp(-3))      --> -0.75  2
print(math.frexp(0.1))     --> 0.8  -3
print(math.frexp(2n^70))   --> 0.5  71
```

[`math.ldexp`](/manual/api#math.ldexp) is the inverse.
