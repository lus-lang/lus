---
name: math.modf
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

Returns the integral part and the fractional part of `x`, where the integral part is rounded toward zero.

`x` is a number of any subtype. A numeric string is converted to a number first.

The results depend on the subtype of `x`:

- An integer returns itself and the float 0.0.
- A float returns its integral part as an integer when it fits in 64 bits and as a float otherwise, then its fractional part as a float. An infinity returns itself and 0.0, and NaN returns NaN twice.
- A bigint returns itself and the float 0.0.
- A decimal returns two decimals, so both parts are exact.

The fractional part has the sign of `x`.

An argument that is not a number raises `bad argument #1 to 'math.modf' (number expected, got nil)` with its type.

```lus
print(math.modf(3.5))      --> 3  0.5
print(math.modf(-3.5))     --> -3  -0.5
print(math.modf(5))        --> 5  0.0
print(math.modf(-3.75d))   --> -3  -0.75
print(math.modf(1/0))      --> inf  0.0
```

The fractional part of a float carries its rounding error, so `math.modf(3.7)` returns 3 and 0.7000000000000002. [`math.floor`](/manual/api#math.floor) and [`math.ceil`](/manual/api#math.ceil) round down and up, and [`math.fmod`](/manual/api#math.fmod) returns the remainder of a division.
