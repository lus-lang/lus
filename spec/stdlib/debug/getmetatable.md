---
name: debug.getmetatable
module: debug
kind: function
since: 0.1.0
pledges: ["debug"]
stability: stable
origin: lua
params:
  - name: value
    type: any
returns: table|nil
---

Returns the metatable of a value, or `nil` when the value has none, ignoring any `__metatable` field.

- `value` is the value to inspect, of any type.

The function returns the metatable itself, even when the metatable holds a `__metatable` field that makes [`getmetatable`](/manual/api#getmetatable) return something else. A value with no metatable returns `nil`. Values other than tables and userdata share one metatable per type, so the result for a string is the metatable of every string. A call with no argument raises `bad argument #1 to 'getmetatable' (value expected)`.

The following example reads a protected metatable and the metatable that all strings share.

```lus
local t = setmetatable({}, { __metatable = "locked" })
print(getmetatable(t))                              --> locked
print(type(debug.getmetatable(t)))                  --> table
print(debug.getmetatable("s").__index == string)    --> true
print(debug.getmetatable(42))                       --> nil
```

[`debug.setmetatable`](/manual/api#debug.setmetatable) sets the metatable of a value of any type.
