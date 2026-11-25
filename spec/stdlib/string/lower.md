---
name: string.lower
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

Returns a copy of `s` with the ASCII letters `A` through `Z` changed to lowercase.

`s` is the string to convert. A number is converted to its textual form first.

The result is a string of the same length. Every character other than `A` through `Z` is unchanged, including letters outside ASCII such as `É`.

An argument that is neither a string nor a number raises a type error.

```lus
print(string.lower("HÉLLO World"))  --> hÉllo world
print(("ABC"):lower())  --> abc
```

[`string.upper`](/manual/api#string.upper) changes the other way.
