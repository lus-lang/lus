---
name: select
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: index
    type: integer|string
vararg: true
returns: any
---

`select(index, ...)` returns the extra arguments from position `index` on, or their count when `index` is the string `"#"`.

The parameter `index` selects the result:

- A positive integer `n` returns the extra arguments from the `n`th to the last. An `n` larger than the count returns no values.
- A negative integer counts back from the end, so `-1` returns the last extra argument.
- The string `"#"` returns the number of extra arguments, including trailing `nil` values.

An `index` of zero, or a negative index that reaches before the first extra argument, raises `bad argument #1 to 'select' (index out of range)`. Any other string raises `number expected`.

```lus
print(select(2, "a", "b", "c"))     --> b  c
print(select(-1, "a", "b", "c"))    --> c
print(select("#", "a", nil, nil))   --> 3
```

`select("#", ...)` is the way to count the arguments of a variadic function that may receive `nil` values, as [Variadic functions](/manual/guide#variadic-functions) describes.
