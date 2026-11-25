---
name: math.random
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: m
    type: integer
    optional: true
  - name: n
    type: integer
    optional: true
returns: number
---

Returns a pseudo-random number: a float in the range from 0 up to 1 when called without arguments, and an integer in a closed range when called with bounds.

The call takes zero, one, or two arguments, each an integer or any number subtype with an integral value. With no arguments, the result is a float `r` with `0 <= r < 1`. With one argument `m`, the result is an integer from 1 to `m`. With two arguments `m` and `n`, the result is an integer from `m` to `n`, both included. The call `math.random(0)` returns an integer whose 64 bits are all random, so it may be any integer.

The generator is xoshiro256\*\*. Each state starts from a seed chosen when the state is created, so two runs produce different sequences unless the program calls [`math.randomseed`](/manual/api#math.randomseed) with a seed of its own.

An empty range, such as `math.random(-5)` or `math.random(5, 1)`, raises `bad argument #1 to 'random' (interval is empty)`. A bound with no integral value raises `number has no integer representation`, and more than two arguments raise `wrong number of arguments`.

```lus
math.randomseed(42)
local r = math.random()
print(r >= 0 and r < 1)  --> true
local die = math.random(6)
print(die >= 1 and die <= 6)  --> true
print(math.random(3, 3))  --> 3
print(math.type(math.random(0)))  --> integer
```

A range of any width up to the whole integer range is uniform, as in `math.random(math.mininteger, math.maxinteger)`. The generator is not suitable for cryptography.
