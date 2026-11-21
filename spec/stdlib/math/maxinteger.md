---
name: math.maxinteger
module: math
kind: constant
since: 0.1.0
stability: stable
origin: lua
type: integer
---

The largest integer, 9223372036854775807, which is 2^63 - 1.

`math.maxinteger` is an integer. Integer arithmetic wraps around on overflow, so `math.maxinteger + 1` is [`math.mininteger`](/manual/api#math.mininteger). Arithmetic that mixes it with a bigint is exact, and arithmetic that mixes it with a float rounds it to 2^63.

```lus
print(math.maxinteger)                              --> 9223372036854775807
print(math.maxinteger + 1 == math.mininteger)       --> true
print(math.maxinteger + 1n)                         --> 9223372036854775808
print(math.maxinteger + 0.0)                        --> 9.2233720368547758e+18
```

A program that needs integers beyond 64 bits uses bigints, written with the suffix `n`, as the [`bigint`](/manual/api#bigint) entry describes.
