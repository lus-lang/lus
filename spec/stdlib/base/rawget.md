---
name: rawget
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: t
    type: table
  - name: k
    type: any
returns: any
---

`rawget(t, k)` returns the value stored at `t[k]`, or `nil` when the key is absent, without calling the `__index` metamethod.

The parameter `t` must be a table, and any other value raises `bad argument #1 to 'rawget' (table expected, got TYPE)`. The parameter `k` is the key and may be any value. A float key with an integral value reads the same field as the integer, so `rawget(t, 1.0)` reads `t[1]`.

```lus
local t = setmetatable({}, {
    __index = function()
        return "default"
    end,
})

t.real = "stored"
print(t.missing, rawget(t, "missing"))  --> default  nil
print(rawget(t, "real"))  --> stored
```

[`rawset`](/manual/api#rawset) writes a field without `__newindex`, and [`rawequal`](/manual/api#rawequal) and [`rawlen`](/manual/api#rawlen) bypass the other metamethods.
