---
name: math.tan
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

Returns the tangent of the angle `x`, given in radians, as a float.

`x` is a number of any subtype. An integer, a bigint, a decimal, and a numeric string are converted to the nearest float first.

The result is a float. An infinite or NaN `x` returns NaN. Near an odd multiple of pi / 2 the result is large, since the nearest float is never exactly such a multiple.

An argument that is not a number raises `bad argument #1 to 'math.tan' (number expected, got nil)` with its type.

```lus
print(math.tan(0))  --> 0.0
print(math.tan(math.pi / 4))  --> 0.9999999999999999
print(math.tan(1))  --> 1.5574077246549023
```

[`math.sin`](/manual/api#math.sin) and [`math.cos`](/manual/api#math.cos) compute the other ratios, and [`math.atan`](/manual/api#math.atan) is the inverse.
