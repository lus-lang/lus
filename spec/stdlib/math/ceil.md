---
name: math.ceil
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

Returns the smallest integral value that is not less than `x`, as an integer when it fits.

`x` is a number of any subtype. A numeric string is converted to a number first.

The result depends on the subtype of `x`:

- An integer returns itself.
- A float returns an integer when the result fits in 64 bits. A float outside that range, an infinity, and NaN return a float, unchanged.
- A bigint returns itself.
- A decimal returns an integer when the result fits in 64 bits, and a bigint otherwise, so the result is always exact.

An argument that is not a number raises `bad argument #1 to 'math.ceil' (number expected, got nil)` with its type.

```lus
print(math.ceil(3.2), math.ceil(-3.5))  --> 4  -3
print(math.ceil(1.25d), math.ceil(7))  --> 2  7
print(math.ceil(1e30d + 0.5d))  --> 1000000000000000000000000000001
print(math.ceil(1e300))  --> 1e+300
print(math.type(math.ceil(2.5)))  --> integer
```

[`math.floor`](/manual/api#math.floor) rounds down, [`math.modf`](/manual/api#math.modf) rounds toward zero, and [`math.tointeger`](/manual/api#math.tointeger) converts a value that is already integral.
