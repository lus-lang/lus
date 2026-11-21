---
name: math.atan
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: y
    type: number
  - name: x
    type: number
    optional: true
returns: number
---

Returns the arc tangent of `y / x` in radians, as a float, using the signs of both arguments to find the quadrant.

`y` and `x` are numbers of any subtype. An integer, a bigint, a decimal, and a numeric string are converted to the nearest float first. `x` defaults to 1, so `math.atan(y)` is the arc tangent of `y`.

The result is a float from -pi to pi. An `x` of zero is valid and gives pi / 2 or -pi / 2 by the sign of `y`. The sign of a zero `y` picks between pi and -pi when `x` is negative.

An argument that is not a number raises `bad argument #1 to 'math.atan' (number expected, got nil)` with its position and type.

```lus
print(math.atan(1))          --> 0.7853981633974483
print(math.atan(1, -1))      --> 2.356194490192345
print(math.atan(-1, -1))     --> -2.356194490192345
print(math.atan(1, 0))       --> 1.5707963267948966
print(math.atan(-0.0, -1))   --> -3.141592653589793
```

[`math.tan`](/manual/api#math.tan) is the inverse of the one-argument form, and [`math.deg`](/manual/api#math.deg) converts the result to degrees.
