---
name: debug.upvaluejoin
module: debug
kind: function
since: 0.1.0
pledges: ["debug"]
stability: stable
origin: lua
params:
  - name: f1
    type: function
  - name: n1
    type: integer
  - name: f2
    type: function
  - name: n2
    type: integer
---

Makes an upvalue of one closure refer to an upvalue of another closure, so that both read and write the same variable, and returns no values.

- `f1` is the Lus function whose upvalue changes.
- `n1` is the index of that upvalue, starting at 1.
- `f2` is the Lus function that holds the upvalue to share.
- `n2` is the index of that upvalue, starting at 1.

After the call, upvalue `n1` of `f1` is the same variable as upvalue `n2` of `f2`, and the variable that `f1` referred to before stays with any other closure that shares it. An `f1` or `f2` that is not a Lus function raises `bad argument #1 to 'upvaluejoin' (Lua function expected)`, or the same error for argument 3. An index outside the upvalues of its function raises `bad argument #2 to 'upvaluejoin' (invalid upvalue index)`, or the same error for argument 4.

The following example joins the counters of two closures made by separate calls.

```lus
local function counter()
    local n = 0
    return function() n = n + 1 return n end
end
local a, b = counter(), counter()
a()
debug.upvaluejoin(b, 1, a, 1)
print(b(), a())                                            --> 2  3
print(debug.upvalueid(a, 1) == debug.upvalueid(b, 1))      --> true
```

Native functions have upvalues of their own that cannot be joined. [`debug.upvalueid`](/manual/api#debug.upvalueid) tells whether two closures already share an upvalue.
