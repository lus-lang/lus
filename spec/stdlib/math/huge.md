---
name: math.huge
module: math
kind: constant
since: 0.1.0
stability: stable
origin: lua
type: number
---

The float positive infinity, which is greater than every other number.

`math.huge` is a float, and `-math.huge` is negative infinity. It compares greater than every integer, float, bigint, and decimal, however large, and it equals `1/0`. [`print`](/manual/api#print) writes it as `inf`.

```lus
print(math.huge, -math.huge)   --> inf  -inf
print(math.huge == 1/0)        --> true
print(math.huge > 2n^5000)     --> true
print(math.type(math.huge))    --> float
```

A float operation whose result is too large for a float, such as `1e308 * 10`, returns `math.huge`. [`math.maxinteger`](/manual/api#math.maxinteger) is the largest integer.
