---
name: math.max
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: x
    type: number
vararg: true
returns: number
---

Returns the argument with the largest value, unchanged and in its own subtype.

The arguments are one or more values. They are compared with the `<` operator, so numbers of every subtype compare by their mathematical value and strings compare with strings.

The result is one of the arguments. When several arguments share the largest value, the first of them is returned, so `math.max(5, 5.0)` is the integer 5. A single argument is returned as it is.

A call with no arguments raises `bad argument #1 to 'math.max' (value expected)`. Arguments that `<` cannot compare, such as a number and a string, raise the comparison error `attempt to compare number with string`.

```lus
print(math.max(1, 5, 3))  --> 5
print(math.max(1, 5.0, 5))  --> 5.0
print(math.max(1, 2n ^ 70, 1.5d))  --> 1180591620717411303424
print(math.max(0.5d, 0.25))  --> 0.5
```

A NaN fails every comparison, so the result depends on its position: `math.max(0/0, 1)` is NaN and `math.max(1, 0/0)` is 1. Comparison of a decimal with a float is exact, although arithmetic between them raises an error. [`math.min`](/manual/api#math.min) returns the smallest argument.
