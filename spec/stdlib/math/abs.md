---
name: math.abs
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

Returns the absolute value of `x`, in the subtype of `x`.

`x` is a number of any subtype. A numeric string is converted to a float first.

An integer returns an integer, a float returns a float, a bigint returns a bigint, and a decimal returns a decimal with the same digits. A negative zero float returns positive zero.

An argument that is not a number raises `bad argument #1 to 'math.abs' (number expected, got nil)` with its type.

```lus
print(math.abs(-3), math.abs(-3.5))  --> 3  3.5
print(math.abs(-(2n ^ 70)))  --> 1180591620717411303424
print(math.abs(-1.25d))  --> 1.25
print(math.abs(math.mininteger))  --> -9223372036854775808
```

Integer arithmetic wraps around, so the absolute value of [`math.mininteger`](/manual/api#math.mininteger) is `math.mininteger` itself, as the last line shows. A bigint holds the exact value: `math.abs(bigint(math.mininteger))` is 9223372036854775808.
