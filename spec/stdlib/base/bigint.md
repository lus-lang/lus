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

`bigint(x)` converts `x` to a bigint, an arbitrary precision integer, and returns it, or returns `nil` when `x` is a string that holds no integer numeral.

The parameter `x` is a number or a string. Integers, bigints, floats with an integral value, and decimals with an integral value convert exactly, and a bigint returns unchanged. A string is trimmed of surrounding whitespace and parsed as a decimal or hexadecimal integer numeral with an optional sign, as in `"-42"` or `"0xff"`.

A float or decimal with a fractional part, and a float that is infinite or NaN, raise `bad argument #1 to 'bigint' (number has no integer representation)`. An argument of any other type raises `number expected`.

A numeral holds at most 16,384 digits, not counting its sign and its `0x` prefix. A string numeral with more digits raises `bigint out of range: more than 16384 digits`, while a longer string that holds no numeral returns `nil`. The limit applies only to text, so arithmetic builds bigints of any size. [`tostring`](/manual/api#tostring) raises the same error for a bigint whose numeral is too long.

```lus
print(bigint(2) ^ 100)  --> 1267650600228229401496703205376
print(bigint("123456789012345678901234567890") + 1)
--> 123456789012345678901234567891
print(bigint(3.0), bigint("0x10"), bigint("1.5"))  --> 3  16  nil
```

The literal suffix `n` writes a bigint directly, as in `42n` or `0xffn`. A string with a fraction, an exponent, or the `n` suffix returns `nil`. The empty string returns `0`. [`math.type`](/manual/api#math.type) reports `"bigint"` for these values, and [`tostring`](/manual/api#tostring) prints them in decimal without a suffix. [`decimal`](/manual/api#decimal) converts to exact base 10 numbers, and [`tonumber`](/manual/api#tonumber) converts a bigint to the nearest float.
