---
name: type
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: v
    type: any
returns: string
---

`type(v)` returns the name of the type of `v` as a string.

The parameter `v` may be any value. The result is one of `"nil"`, `"boolean"`, `"number"`, `"string"`, `"table"`, `"function"`, `"thread"`, `"userdata"`, `"vector"`, `"enum"`, and `"query"`. A call with no arguments raises `bad argument #1 to 'type' (value expected)`.

```lus
print(type(nil), type(42), type("hi"), type({}))  --> nil  number  string  table
print(type(print), type(vector.create(4)))  --> function  vector
print(type(5n), type(1.5d))  --> number  number
```

Every number reports `"number"`, and [`math.type`](/manual/api#math.type) distinguishes the subtypes `integer`, `float`, `bigint`, and `decimal`. An enum and each of its members report `"enum"`. The [Values](/manual/guide#values-and-types) section of the guide describes each type.
