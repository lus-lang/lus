---
name: math.ldexp
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: m
    type: number
  - name: e
    type: integer
returns: number
---

Returns `m * 2^e` as a float.

`m` is a number of any subtype. An integer, a bigint, a decimal, and a numeric string are converted to the nearest float first. `e` is the exponent, an integer or any number subtype with an integral value.

The result is a float. A result too large for a float is `inf`, and one too small is zero.

An `e` with no integral value raises `bad argument #2 to 'math.ldexp' (number has no integer representation)`. An argument that is not a number raises a type error.

```lus
print(math.ldexp(0.5, 4))    --> 8.0
print(math.ldexp(3, -1))     --> 1.5
print(math.ldexp(1, 1024))   --> inf
```

[`math.frexp`](/manual/api#math.frexp) is the inverse.
