---
name: rawequal
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: v1
    type: any
  - name: v2
    type: any
returns: boolean
---

`rawequal(v1, v2)` returns `true` when `v1` and `v2` are primitively equal and `false` otherwise, without calling the `__eq` metamethod.

Both parameters may be values of any type. Numbers compare by mathematical value, so `rawequal(1, 1.0)` is `true`. Strings compare by content. Tables, functions, threads, and userdata are equal only when they are the same object. A call with fewer than two arguments raises `bad argument #2 to 'rawequal' (value expected)`.

```lus
local always = {
    __eq = function()
        return true
    end,
}

local a, b = setmetatable({}, always), setmetatable({}, always)
print(a == b, rawequal(a, b))  --> true  false
print(rawequal(1, 1.0), rawequal("x", "x"))  --> true  true
```

[`rawget`](/manual/api#rawget), [`rawset`](/manual/api#rawset), and [`rawlen`](/manual/api#rawlen) bypass the other table metamethods.
