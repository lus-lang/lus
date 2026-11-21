---
name: debug.upvalueid
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: f
    type: function
  - name: n
    type: integer
returns: userdata|nil
---

Returns a light userdata that identifies an upvalue of a function, or `nil` when the function has no upvalue at that index.

- `f` is a Lus function or a native function.
- `n` is the index of the upvalue, starting at 1.

Two closures that share an upvalue return identifiers that are equal, and closures with separate upvalues return identifiers that differ, even when the values in them are equal. An index below 1 or above the number of upvalues returns `nil`. An `f` that is not a function raises `bad argument #1 to 'upvalueid' (function expected)`.

The following example compares the upvalues of closures made by two calls of the same function.

```lus
local function counter()
    local n = 0
    return function() n = n + 1 return n end, function() return n end
end
local inc, get = counter()
local other = counter()
print(debug.upvalueid(inc, 1) == debug.upvalueid(get, 1))      --> true
print(debug.upvalueid(inc, 1) == debug.upvalueid(other, 1))    --> false
print(type(debug.upvalueid(inc, 1)), debug.upvalueid(inc, 9))  --> userdata  nil
```

An identifier stays valid only while the upvalue exists, and its address carries no other meaning. [`debug.upvaluejoin`](/manual/api#debug.upvaluejoin) makes two closures share an upvalue.
