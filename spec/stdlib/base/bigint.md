---
name: bigint
module: base
kind: function
since: 2.0.0
stability: stable
origin: lus
params:
  - name: x
    type: number|string
returns: number|nil
---

Converts `x` to a bigint, an arbitrary precision integer. Integers, bigints, floats with an integral value, and decimals with an integral value convert exactly. A string is parsed as an integer numeral, and a string that holds no such numeral returns `nil`. A float or decimal with a fractional part raises an error.

```lus
print(bigint(2) ^ 100)    --> 1267650600228229401496703205376
print(bigint("123456789012345678901234567890") + 1)
```

The literal suffix `n` writes a bigint directly, as in `42n` or `0xffn`. `math.type` reports `"bigint"` for these values, and `tostring` prints them in decimal without a suffix.
