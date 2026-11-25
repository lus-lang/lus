---
name: math.sin
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

Returns the sine of the angle `x`, given in radians, as a float.

`x` is a number of any subtype. An integer, a bigint, a decimal, and a numeric string are converted to the nearest float first.

The result is a float from -1 to 1. An infinite or NaN `x` returns NaN.

An argument that is not a number raises `bad argument #1 to 'math.sin' (number expected, got nil)` with its type.

```lus
print(math.sin(0))  --> 0.0
print(math.sin(math.pi / 2))  --> 1.0
print(math.sin(math.pi))  --> 1.2246467991473532e-16
```

`math.pi` is the float nearest to pi, so the sine of `math.pi` is a small number close to zero. [`math.cos`](/manual/api#math.cos) and [`math.tan`](/manual/api#math.tan) compute the other ratios, [`math.asin`](/manual/api#math.asin) is the inverse, and [`math.rad`](/manual/api#math.rad) converts degrees to radians.
