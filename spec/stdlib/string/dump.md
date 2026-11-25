---
name: string.dump
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: function
    type: function
  - name: strip
    type: boolean
    optional: true
returns: vector
---

Returns a vector that holds `function` as a binary chunk, which [`load`](/manual/api#load) turns back into a copy of the function.

`function` is a function written in Lus. When `strip` is true, the chunk leaves out debug information such as line numbers and the names of locals, so it is smaller. `strip` defaults to false.

The result is a new vector on every call.

A function with native code, such as `print`, raises the error `unable to dump given function`. An argument that is not a function raises a type error.

```lus
pledge("load")

local chunk = string.dump(function(a)
    return a * 2
end)

local double = load(chunk, "double", "b")
print(type(chunk), double(21))  --> vector  42
```

The loaded function has fresh upvalues. `load` sets its first upvalue to the global environment and leaves the others `nil`, so a function that captured locals reads different values after the round trip. An error raised by a function loaded from a stripped chunk carries no line number. Loading a chunk requires the `load` [permission](/manual/permissions).

The result is a version-dependent runtime artifact for trusted storage and distribution. It can include captured bytecode structure. Accept text-only source with `load` mode `"t"` when input crosses an untrusted boundary.
