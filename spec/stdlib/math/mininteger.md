---
name: math.mininteger
module: math
kind: constant
since: 0.1.0
stability: stable
origin: lua
type: integer
---

The smallest integer, -9223372036854775808, which is -2^63.

`math.mininteger` is an integer. Integer arithmetic wraps around on overflow, so `math.mininteger - 1` is [`math.maxinteger`](/manual/api#math.maxinteger), and `-math.mininteger` and `math.abs(math.mininteger)` are `math.mininteger` itself. Arithmetic that mixes it with a bigint is exact.

```lus
print(math.mininteger)  --> -9223372036854775808
print(math.mininteger - 1 == math.maxinteger)  --> true
print(-math.mininteger == math.mininteger)  --> true
print(-bigint(math.mininteger))  --> 9223372036854775808
```

`string.format("%q", math.mininteger)` writes it in hexadecimal, as `0x8000000000000000`, because its decimal form would read back as a float.
