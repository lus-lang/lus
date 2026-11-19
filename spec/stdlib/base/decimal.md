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

Converts `x` to a decimal, an exact base 10 number. Integers, bigints, and numeric strings convert exactly and keep their digits, so `decimal("2.50")` keeps two fractional digits. A float converts through the shortest decimal string that reads back as the same float, so `decimal(0.1)` is `0.1`. A string that holds no numeral returns `nil`.

```lus
print(decimal("0.1") + decimal("0.2") == decimal("0.3"))   --> true
print(decimal(1) / 3)    --> 0.3333333333333333333333333333333333
```

The literal suffix `d` writes a decimal directly, as in `1.50d` or `1e-2d`. Division of decimals rounds to 34 significant digits, half to even. Arithmetic between a decimal and a float raises an error, so a program converts one side explicitly with `decimal` or `tonumber`. `math.type` reports `"decimal"` for these values, and `tostring` prints exactly their stored digits.
