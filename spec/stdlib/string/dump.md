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

Returns a vector containing a serialized representation of `function`, so that a compatible later `load` returns a copy of the function. If `strip` is true, debug information is omitted. A function with native code, such as `print`, raises an error.

```lus
local chunk = string.dump(function(a) return a * 2 end)
local double = load(chunk, "double", "b")
print(double(21))   --> 42
```

The result is a version-dependent runtime artifact for trusted storage and distribution. It can include captured bytecode structure. Accept text-only source with `load` mode `"t"` when input crosses an untrusted boundary.
