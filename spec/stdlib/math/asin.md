---
name: math.asin
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

Returns the arc sine of `x` in radians, as a float.

`x` is a number of any subtype. An integer, a bigint, a decimal, and a numeric string are converted to the nearest float first.

The result is a float from -pi / 2 to pi / 2. An `x` outside the range from -1 to 1 returns NaN.

An argument that is not a number raises `bad argument #1 to 'math.asin' (number expected, got nil)` with its type.

```lus
print(math.asin(0))  --> 0.0
print(math.asin(1))  --> 1.5707963267948966
print(math.asin(0.5d))  --> 0.5235987755982989
print(math.asin(2))  --> nan
```

[`math.sin`](/manual/api#math.sin) is the inverse, and [`math.deg`](/manual/api#math.deg) converts the result to degrees.
