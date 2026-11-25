---
name: decimal
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

`decimal(x)` converts `x` to a decimal, an exact base 10 number, and returns it, or returns `nil` when `x` is a string that holds no numeral.

The parameter `x` is a number or a string. Integers, bigints, and numeric strings convert exactly and keep their digits, so `decimal("2.50")` keeps two fractional digits. A string is trimmed of surrounding whitespace and parsed as a decimal numeral with an optional sign, fraction, and exponent. A float converts through the shortest decimal string that reads back as the same float, so `decimal(0.1)` is `0.1`. A decimal returns unchanged. An argument of any other type raises `bad argument #1 to 'decimal' (number expected, got TYPE)`.

```lus
print(decimal("0.1") + decimal("0.2") == decimal("0.3"))  --> true
print(decimal(1) / 3)  --> 0.3333333333333333333333333333333333
print(decimal("2.50") * 2)  --> 5.00
```

A hexadecimal string, a string with the `d` suffix, and an infinite or NaN float return `nil`. A decimal holds at most 131,072 digits before the point and 16,383 after, the limits of the `numeric` type of PostgreSQL, so a numeral or a bigint that needs more raises `decimal out of range: more than 131072 digits before the point`, or `more than 16383 digits after the point`, and so does any arithmetic result past the limits. The literal suffix `d` writes a decimal directly, as in `1.50d` or `1e-2d`. Division of decimals rounds to 34 significant digits, half to even. Arithmetic between a decimal and a float raises `attempt to mix decimal and float in arithmetic`, so a program converts one side explicitly with `decimal` or [`tonumber`](/manual/api#tonumber). [`math.type`](/manual/api#math.type) reports `"decimal"` for these values, and [`tostring`](/manual/api#tostring) prints exactly their stored digits. [`bigint`](/manual/api#bigint) converts to arbitrary precision integers.
