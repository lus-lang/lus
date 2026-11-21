---
name: math.type
module: math
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: x
    type: any
returns: string|nil
---

Returns the subtype of the number `x` as a string: `"integer"`, `"float"`, `"bigint"`, or `"decimal"`.

`x` is any value.

The result is one of the four names when `x` is a number, and `nil` when it is not. A numeric string is not a number, so it returns `nil`.

A call with no argument raises `bad argument #1 to 'math.type' (value expected)`.

```lus
print(math.type(1), math.type(1.0))     --> integer  float
print(math.type(1n), math.type(1d))     --> bigint  decimal
print(math.type("1"), math.type(nil))   --> nil  nil
```

The four subtypes are values of the one type `number`, so `type(x)` returns `"number"` for each of them. The [`number`](/manual/guide#numbers) section of the guide describes how arithmetic picks the subtype of a result.
