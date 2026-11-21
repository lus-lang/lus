---
name: tostring
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

`tostring(v)` converts `v` to a human-readable string and returns it.

The parameter `v` may be a value of any type. If `v` has a `__tostring` metamethod, `tostring` calls it with `v` and returns its result, converting a number result to a string. A result of any other type raises `'__tostring' must return a string`. Without the metamethod, the conversion depends on the type:

- `nil` and booleans become `"nil"`, `"true"`, and `"false"`.
- An integer prints in decimal. A float prints with 14 significant digits, or with the fewest digits up to 17 that read back as the same float when 14 do not, so `1 / 3` prints as `"0.3333333333333333"` and `0.1 + 0.2` as `"0.30000000000000004"`. A float always shows that it is a float, so `1.0` prints as `"1.0"` and large values use an exponent, as in `"1e+100"`.
- A bigint prints in decimal without its `n` suffix, and a decimal prints exactly its stored digits, so `tostring(1.50d)` is `"1.50"`.
- A string returns unchanged.
- Any other value prints as its type and its address, as in `"table: 0x000001049d7cf0"`. A table whose metatable has a string `__name` field uses that name in place of the type.

A call with no arguments raises `bad argument #1 to 'tostring' (value expected)`.

```lus
print(tostring(12), tostring(1.0), tostring(1.50d))   --> 12  1.0  1.50
local point = setmetatable({}, { __tostring = function() return "point(1, 2)" end })
print(tostring(point))                                --> point(1, 2)
print(tostring({}):match("^table: ") ~= nil)          --> true
```

[`print`](/manual/api#print) converts its arguments with the same rules, and [`string.format`](/manual/api#string.format) controls the number of digits.
