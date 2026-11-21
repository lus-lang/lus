---
name: math.fmod
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: x
    type: number
  - name: y
    type: number
returns: number
---

Returns the remainder of the division of `x` by `y`, with the quotient rounded toward zero, so the result has the sign of `x`.

`x` and `y` are numbers of any subtype. A numeric string is converted to a number first.

The subtype of the result follows the arguments:

- Two integers return an integer.
- A bigint with an integer or a bigint returns a bigint.
- A decimal with an integer, a bigint, or a decimal returns a decimal.
- Any pair with a float returns a float, which includes a decimal with a float.

A float `y` of zero returns NaN, and an infinite `y` returns `x` as a float.

A zero `y` that is an integer, a bigint, or a decimal raises `bad argument #2 to 'math.fmod' (zero)`. An argument that is not a number raises a type error.

```lus
print(math.fmod(7, 3), math.fmod(-7, 3))   --> 1  -1
print(math.fmod(7.5, 2))                   --> 1.5
print(math.fmod(-7n, 3))                   --> -1
print(math.fmod(7.5d, 2d))                 --> 1.5
print(math.fmod(7, 0.0))                   --> nan
```

`math.fmod(math.mininteger, -1)` is 0. The `%` operator rounds the quotient toward minus infinity, so its result has the sign of `y`: `-7 % 3` is 2. [`math.modf`](/manual/api#math.modf) splits a number into its integral and fractional parts.
