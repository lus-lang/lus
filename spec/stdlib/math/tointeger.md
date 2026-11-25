---
name: math.tointeger
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: x
    type: number
returns: integer|nil
---

Converts `x` to an integer and returns it, or returns `nil` when `x` has no integer value.

`x` is any value. A number of any subtype converts when its value is integral and fits in 64 bits. A string converts when it holds a numeral with such a value, in decimal or hexadecimal, with surrounding spaces allowed.

The result is an integer on success and `nil` otherwise. A value of another type, such as a table, returns `nil` without an error.

A call with no argument raises `bad argument #1 to 'math.tointeger' (value expected)`.

```lus
print(math.tointeger(3.0), math.tointeger(3.5))  --> 3  nil
print(math.tointeger(5n), math.tointeger(5.00d))  --> 5  5
print(math.tointeger(2n ^ 70), math.tointeger(2 ^ 63))  --> nil  nil
print(math.tointeger("8"), math.tointeger(" 0x10 "))  --> 8  16
print(math.tointeger("x"), math.tointeger({}))  --> nil  nil
```

A string with a bigint or decimal suffix, such as `"5n"`, returns `nil`. [`math.floor`](/manual/api#math.floor) and [`math.ceil`](/manual/api#math.ceil) round a value that is not integral, and [`math.type`](/manual/api#math.type) tells whether a number is an integer already.
