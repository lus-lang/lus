---
name: string.upper
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: s
    type: string
returns: string
---

Returns a copy of `s` with the ASCII letters `a` through `z` changed to uppercase.

`s` is the string to convert. A number is converted to its textual form first.

The result is a string of the same length. Every character other than `a` through `z` is unchanged, including letters outside ASCII such as `é`.

An argument that is neither a string nor a number raises a type error.

```lus
print(string.upper("héllo world"))  --> HéLLO WORLD
print(("abc"):upper())              --> ABC
```

[`string.lower`](/manual/api#string.lower) changes the other way.
