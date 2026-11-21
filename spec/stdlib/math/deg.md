---
name: math.deg
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

Converts the angle `x` from radians to degrees and returns it as a float.

`x` is a number of any subtype. An integer, a bigint, a decimal, and a numeric string are converted to the nearest float first.

The result is the float `x * (180 / pi)`.

An argument that is not a number raises `bad argument #1 to 'math.deg' (number expected, got nil)` with its type.

```lus
print(math.deg(math.pi))   --> 180.0
print(math.deg(1))         --> 57.29577951308232
```

[`math.rad`](/manual/api#math.rad) converts the other way.
