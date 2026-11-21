---
name: math.floor
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: x
    type: number
returns: integer
---

Returns the largest integral value that is not greater than `x`, as an integer when it fits.

`x` is a number of any subtype. A numeric string is converted to a number first.

The result depends on the subtype of `x`:

- An integer returns itself.
- A float returns an integer when the result fits in 64 bits. A float outside that range, an infinity, and NaN return a float, unchanged.
- A bigint returns itself.
- A decimal returns an integer when the result fits in 64 bits, and a bigint otherwise, so the result is always exact.

An argument that is not a number raises `bad argument #1 to 'math.floor' (number expected, got nil)` with its type.

```lus
print(math.floor(3.7), math.floor(-3.5))   --> 3  -4
print(math.floor(-1.25d), math.floor(7))   --> -2  7
print(math.floor(1e300))                   --> 1e+300
print(math.floor("2.5"))                   --> 2
```

Floor division `x // 1` keeps the subtype of `x`, so it returns a float for a float. [`math.ceil`](/manual/api#math.ceil) rounds up, and [`math.modf`](/manual/api#math.modf) rounds toward zero.
