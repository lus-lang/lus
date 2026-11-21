---
name: math.pi
module: math
kind: constant
since: 0.1.0
stability: stable
origin: lua
type: number
---

The float closest to pi, 3.141592653589793.

`math.pi` is a float. [`print`](/manual/api#print) writes it with the fewest digits that read back as the same float, as `3.141592653589793`.

```lus
print(math.pi)                    --> 3.141592653589793
print(math.pi == 4 * math.atan(1))  --> true
print(math.cos(math.pi))          --> -1.0
```

A float holds pi to about 16 significant digits, so trigonometric results at multiples of `math.pi` carry a small error, as [`math.sin`](/manual/api#math.sin) shows. [`math.rad`](/manual/api#math.rad) and [`math.deg`](/manual/api#math.deg) convert between degrees and radians.
