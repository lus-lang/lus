---
name: math.acos
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

Returns the arc cosine of `x` in radians, as a float.

`x` is a number of any subtype. An integer, a bigint, a decimal, and a numeric string are converted to the nearest float first.

The result is a float from 0 to pi. An `x` outside the range from -1 to 1 returns NaN.

An argument that is not a number raises `bad argument #1 to 'math.acos' (number expected, got nil)` with its type.

```lus
print(math.acos(1))      --> 0.0
print(math.acos(-1))     --> 3.141592653589793
print(math.acos(0.5d))   --> 1.0471975511965979
print(math.acos(2))      --> nan
```

[`math.cos`](/manual/api#math.cos) is the inverse, and [`math.deg`](/manual/api#math.deg) converts the result to degrees.
