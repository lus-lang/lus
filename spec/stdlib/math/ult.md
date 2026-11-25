---
name: math.ult
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: m
    type: integer
  - name: n
    type: integer
returns: boolean
---

Returns `true` when the integer `m` is less than the integer `n` when both are read as unsigned 64-bit integers, and `false` otherwise.

`m` and `n` are integers, or any number subtype with an integral value that fits in 64 bits. A numeric string is converted to a number first. A negative integer reads as its two's complement, so -1 is the largest unsigned value.

The result is a boolean.

An argument with no integral value, or a bigint outside 64 bits, raises `bad argument #1 to 'math.ult' (number has no integer representation)` with its position. An argument that is not a number raises a type error.

```lus
print(math.ult(1, 2))  --> true
print(math.ult(-1, 2))  --> false
print(math.ult(2, -1))  --> true
print(math.ult(1.0, 2n))  --> true
```

The `<` operator compares the same integers as signed values. [`math.maxinteger`](/manual/api#math.maxinteger) is the largest signed value.
