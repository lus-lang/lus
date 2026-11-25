---
name: math.log
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: x
    type: number
  - name: base
    type: number
    optional: true
returns: number
---

Returns the logarithm of `x` in the given `base`, as a float.

`x` and `base` are numbers of any subtype. An integer, a bigint, a decimal, and a numeric string are converted to the nearest float first. `base` defaults to *e*, which gives the natural logarithm.

The result is a float. A base of 2 or 10 uses a dedicated routine, so the logarithm of an exact power of that base is exact. An `x` of zero returns `-inf`, and a negative `x` returns NaN.

An argument that is not a number raises `bad argument #1 to 'math.log' (number expected, got nil)` with its position and type.

```lus
print(math.log(1))  --> 0.0
print(math.log(8, 2))  --> 3.0
print(math.log(1000, 10))  --> 3.0
print(math.log(2n ^ 100, 2))  --> 100.0
print(math.log(0))  --> -inf
```

The conversion to a float comes first, so a bigint or decimal beyond the float range, about 1.8e308, has a logarithm of `inf`. [`math.exp`](/manual/api#math.exp) is the inverse of the natural logarithm.
