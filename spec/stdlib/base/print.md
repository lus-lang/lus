---
name: print
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
vararg: true
---

`print(...)` writes its arguments to standard output, separated by tab characters and followed by a newline, and returns no values.

Each argument may be of any type. A string is written as it is, and any other value is converted as [`tostring`](/manual/api#tostring) converts it, so a `__tostring` metamethod decides how a table prints. A call with no arguments writes an empty line. A `__tostring` metamethod that returns a value other than a string or a number raises `'__tostring' must return a string`.

```lus
print("total", 3, 1.0, nil, true)  --> total  3  1.0  nil  true

print(setmetatable({}, {
    __tostring = function()
        return "point(1, 2)"
    end,
}))
--> point(1, 2)
```

`print` is meant for quick output. [`io.write`](/manual/api#io.write) writes values without separators or a newline, and [`string.format`](/manual/api#string.format) controls the format of each value.
