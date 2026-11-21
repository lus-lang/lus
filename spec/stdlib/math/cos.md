---
name: math.cos
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

Returns the cosine of the angle `x`, given in radians, as a float.

`x` is a number of any subtype. An integer, a bigint, a decimal, and a numeric string are converted to the nearest float first.

The result is a float from -1 to 1. An infinite or NaN `x` returns NaN.

An argument that is not a number raises `bad argument #1 to 'math.cos' (number expected, got nil)` with its type.

```lus
print(math.cos(0))         --> 1.0
print(math.cos(math.pi))   --> -1.0
print(math.cos(1n))        --> 0.54030230586813977
```

[`math.sin`](/manual/api#math.sin) and [`math.tan`](/manual/api#math.tan) compute the other ratios, [`math.acos`](/manual/api#math.acos) is the inverse, and [`math.rad`](/manual/api#math.rad) converts degrees to radians.
