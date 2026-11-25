---
name: math.exp
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

Returns *e* raised to the power `x`, as a float.

`x` is a number of any subtype. An integer, a bigint, a decimal, and a numeric string are converted to the nearest float first.

The result is a positive float. A result too large for a float is `inf`, and `-math.huge` returns 0.0.

An argument that is not a number raises `bad argument #1 to 'math.exp' (number expected, got nil)` with its type.

```lus
print(math.exp(0))  --> 1.0
print(math.exp(1))  --> 2.7182818284590455
print(math.exp(710))  --> inf
```

[`math.log`](/manual/api#math.log) is the inverse. The `^` operator raises any base to a power.
