---
name: math.min
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

Returns the argument with the smallest value, unchanged and in its own subtype.

The arguments are one or more values. They are compared with the `<` operator, so numbers of every subtype compare by their mathematical value and strings compare with strings.

The result is one of the arguments. When several arguments share the smallest value, the first of them is returned. A single argument is returned as it is.

A call with no arguments raises `bad argument #1 to 'math.min' (value expected)`. Arguments that `<` cannot compare, such as a number and a string, raise the comparison error `attempt to compare number with string`.

```lus
print(math.min(3, 1.5, 2))  --> 1.5
print(math.min(-2n, -1.5d))  --> -2
print(math.min(7))  --> 7
print(math.min("b", "a"))  --> a
```

A NaN fails every comparison, so the result depends on its position: `math.min(0/0, 1)` is NaN and `math.min(1, 0/0)` is 1. [`math.max`](/manual/api#math.max) returns the largest argument.
