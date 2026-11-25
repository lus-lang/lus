---
name: getmetatable
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: object
    type: any
returns: table|nil
---

`getmetatable(object)` returns the metatable of `object`, or `nil` when it has none.

The parameter `object` may be a value of any type. Tables carry their own metatables, and strings share one metatable whose `__index` field is the `string` library.

If the metatable has a `__metatable` field, `getmetatable` returns the value of that field in place of the metatable. A call with no arguments raises `bad argument #1 to 'getmetatable' (value expected)`.

```lus
local mt = {}
local t = setmetatable({}, mt)
print(getmetatable(t) == mt, getmetatable({}))  --> true  nil
print(getmetatable("").__index == string)  --> true

mt.__metatable = "locked"
print(getmetatable(t))  --> locked
```

A `__metatable` field also makes [`setmetatable`](/manual/api#setmetatable) refuse to change the metatable. [Metatables and metamethods](/manual/guide#metatables-and-objects) in the guide lists the metamethods.
