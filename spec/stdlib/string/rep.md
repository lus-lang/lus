---
name: string.rep
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: s
    type: string
  - name: n
    type: integer
  - name: sep
    type: string
    optional: true
returns: string
---

Returns a string made of `n` copies of `s`, with `sep` between each pair of copies.

`s` is the string to repeat. A number is converted to its textual form first. `n` is the number of copies, an integer or any number subtype with an integral value. `sep` is the separator and defaults to the empty string.

The result is a string of `n` copies of `s` and `n - 1` copies of `sep`. When `n` is 0 or negative, the result is the empty string.

A result too large to allocate raises `resulting string too large`. An `n` with no integral value raises `bad argument #2 to 'rep' (number has no integer representation)`.

```lus
print(string.rep("ab", 3))  --> ababab
print(string.rep("ab", 3, ", "))  --> ab, ab, ab
print(string.rep("x", 1, ","))  --> x
print(string.rep("x", 0) == "")  --> true
print(#string.rep("é", 4))  --> 4
```

[`string.format`](/manual/api#string.format) pads with spaces through a width, and [`string.join`](/manual/api#string.join) joins different strings with a separator.
