---
name: rawset
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: t
    type: T
  - name: k
    type: any
  - name: v
    type: any
generic: T
returns: T
---

`rawset(t, k, v)` stores `v` at `t[k]` without calling the `__newindex` metamethod and returns `t`.

The parameter `t` must be a table, and any other value raises `bad argument #1 to 'rawset' (table expected, got TYPE)`. The parameter `k` is the key and `v` the value, and both must be present. A `v` of `nil` removes the field. A `nil` key raises `table index is nil`, and a NaN key raises `table index is NaN`.

```lus
local log = {}

local t = setmetatable({}, {
    __newindex = function(_, k)
        log[#log + 1] = k
    end,
})

t.a = 1
rawset(t, "b", 2)
print(t.a, t.b, #log)  --> nil  2  1
```

[`rawget`](/manual/api#rawget) reads a field without `__index`. A table that `--readonly-env` froze raises `attempt to modify a readonly table` for `rawset` as it does for assignment, as [Readonly environment](/manual/guide#the---readonly-env-option) describes.
