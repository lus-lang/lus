---
name: math.rad
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

Converts the angle `x` from degrees to radians and returns it as a float.

`x` is a number of any subtype. An integer, a bigint, a decimal, and a numeric string are converted to the nearest float first.

The result is the float `x * (pi / 180)`.

An argument that is not a number raises `bad argument #1 to 'math.rad' (number expected, got nil)` with its type.

```lus
print(math.rad(180))   --> 3.1415926535897931
print(math.rad(90))    --> 1.5707963267948966
```

The trigonometric functions such as [`math.sin`](/manual/api#math.sin) take radians. [`math.deg`](/manual/api#math.deg) converts the other way.
