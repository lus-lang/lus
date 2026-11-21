---
name: math.randomseed
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: x
    type: integer
    optional: true
  - name: y
    type: integer
    optional: true
returns:
  - name: x
    type: integer
  - name: y
    type: integer
---

Seeds the pseudo-random generator of [`math.random`](/manual/api#math.random) and returns the two integers that make up the seed.

`x` and `y` are integers, or any number subtype with an integral value, that together form the seed. `y` defaults to 0. With no arguments, the generator is seeded with a fresh value that the runtime chooses.

The results are the two parts of the seed, as integers. A call with no arguments returns the parts it chose, so a program can record them and pass them back later to replay the same sequence.

An argument with no integral value raises `bad argument #1 to 'randomseed' (number has no integer representation)`, and an argument that is not a number raises `bad argument #1 to 'randomseed' (number expected, got string)` with its type.

```lus
print(math.randomseed(42))     --> 42  0
local a = math.random(1000)
math.randomseed(42)
print(math.random(1000) == a)  --> true
local x, y = math.randomseed()
math.randomseed(x, y)
```

Equal seeds produce equal sequences on every platform. Each Lus state has a generator of its own.
