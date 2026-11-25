---
name: tonumber
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: e
    type: any
  - name: base
    type: integer
    optional: true
returns: number|nil
---

`tonumber(e, base)` converts `e` to a number and returns it, or returns `nil` when `e` cannot be converted.

The parameter `e` is the value to convert. Without `base`, the conversion depends on its type:

- An integer or a float returns unchanged.
- A bigint or a decimal converts to the nearest float, which makes `tonumber` the explicit way to mix an exact number with float arithmetic.
- A string is trimmed of surrounding whitespace and parsed as a decimal or hexadecimal numeral. An integer numeral that overflows 64 bits becomes a float. The suffixes `n` and `d` are not part of the numeral and make the result `nil`.
- An enum member returns its 1-based position in its enum.
- Any other value returns `nil`.

The optional `base` is an integer from 2 through 36. With `base`, `e` must be a string that holds an integer numeral in that base, with an optional sign. The letters `a` through `z`, in either case, stand for the digits 10 through 35. A string with a digit outside the base returns `nil`.

A `base` outside 2 through 36 raises `bad argument #2 to 'tonumber' (base out of range)`, and a non-string `e` with a `base` raises `bad argument #1 to 'tonumber' (string expected, got TYPE)`. A call with no arguments raises `bad argument #1 to 'tonumber' (value expected)`.

```lus
print(tonumber("42"), tonumber(" 0x1F "), tonumber("1e2"))  --> 42  31  100.0
print(tonumber("ff", 16), tonumber("-101", 2), tonumber("z", 10))  --> 255  -5  nil
print(tonumber(1.50d), math.type(tonumber(5n)))  --> 1.5  float
```

[`bigint`](/manual/api#bigint) and [`decimal`](/manual/api#decimal) convert strings to exact numbers, and [`math.tointeger`](/manual/api#math.tointeger) converts a float with an integral value to an integer.
